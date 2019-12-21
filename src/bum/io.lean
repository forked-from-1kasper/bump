import Init.System.IO
import Init.System.FilePath
import bum.parser

def Lean.deps := [ "-lpthread", "-lgmp" ]
def Lean.libraries (leanHome : String) := 
List.joinPath <$>
  [ [ leanHome, "bin", "libleanstatic.a" ],
    [ leanHome, "bin", "libleanstdlib.a" ] ]
def Lean.cppOptions := [ "-fPIC", "-Wno-unused-command-line-argument" ]

def config := "bum.config"

def runCmdPretty (additionalInfo s : String) : IO Unit := do
  IO.println ("==> " ++ s ++ " " ++ additionalInfo);
  exitv ← IO.runCmd s;
  let errorStr := "process exited with code " ++ toString exitv;
  IO.cond (exitv ≠ 0) (throw errorStr)

def sourceOlean (tools : Tools) : Source → Option (List String)
| src@(Source.lean path) ⇒
  some [ [ tools.lean, "--make", src.path ].space ]
| _ ⇒ none

def sourceCommands (tools : Tools) : Source → List String
| src@(Source.lean path) ⇒
  List.space <$>
    [ [ tools.lean, "--make", src.path ],
      [ tools.lean, "-c", src.asCpp, src.path ],
      [ tools.leanc, "-c", src.asCpp, "-o", src.obj ] ]
| src@(Source.cpp path) ⇒
  List.space <$>
    [ [ tools.leanc, "-c", src.path, "-o", src.obj ] ]

def sourceLink
  (output : String) (tools : Tools)
  (files : List Source) (flags : List String) :=
List.space $ [ tools.ar, "rvs", output ] ++ Source.obj <$> files ++ flags

def sourceCompile (output : String) (tools : Tools)
  (files : List Source) (libs flags : List String) :=
List.space $
  pure tools.cpp ++ Lean.cppOptions ++
  [ "-o",  output ] ++
  (Source.obj <$> files).reverse ++
  libs.reverse ++ flags

def compileCommands
  (conf : Project) (tools : Tools)
  (libs flags : List String) :=
match conf.build with
| BuildType.executable ⇒
  List.join (sourceCommands tools <$> conf.files) ++
  [ sourceCompile conf.getBinary tools conf.files libs flags ]
| BuildType.library ⇒
  List.join (sourceCommands tools <$> conf.files) ++
  [ sourceLink conf.getBinary tools conf.files flags ]

def oleanCommands (conf : Project) (tools : Tools) :=
List.join (List.filterMap (sourceOlean tools) conf.files)

def procents {α : Type} (xs : List α) : List (Nat × α) :=
(λ (p : Nat × α) ⇒ (p.1 * 100 / xs.length, p.2)) <$> xs.enum

def compileProject (conf : Project) (tools : Tools) (libs : List String) : IO Unit :=
let runPretty :=
λ (p : Nat × String) ⇒ runCmdPretty ("(" ++ toString p.1 ++ " %)") p.2;
let actions := runPretty <$> procents (compileCommands conf tools libs conf.cppFlags);
IO.println ("Compiling " ++ conf.name) >> forM' id actions

def silentRemove (filename : String) : IO Unit :=
do IO.remove filename; pure ()

structure Pkg :=
(name path : String)

def String.addToPath (dest delta : String) :=
match dest with
| "" ⇒ delta
| _  ⇒ dest ++ ":" ++ delta

def addToLeanPath (pkg : Pkg) : IO Unit :=
let pkgStr := pkg.name ++ "=" ++ pkg.path; do
  path ← IO.getEnv "LEAN_PATH";
  match path with
  | none    ⇒ IO.setEnv "LEAN_PATH" pkgStr
  | some v  ⇒ IO.setEnv "LEAN_PATH" (v.addToPath pkgStr);
  pure ()

partial def resolveDepsAux (depsDir : String) (download : Bool) :
  String → Dep → IO (List Project)
| parent, dep ⇒ do
  let confPath := [ depsDir, dep.name, config ].joinPath;

  isThere ← IO.fileExists confPath;
  IO.cond (¬isThere ∧ download) (do
    IO.println ("==> downloading " ++ dep.name ++ " (of " ++ parent ++ ")");
    exitv ← IO.runCmd (Dep.cmd depsDir dep);
    let err :=
      "downloading of “" ++ dep.name ++
      "” failed with code " ++ toString exitv;
    IO.cond (exitv ≠ 0) (throw err));

  conf ← readConf confPath;
  projects ← sequence (resolveDepsAux dep.name <$> conf.deps);
  pure (List.join projects ++ [ conf ])

def resolveDeps (conf : Project) (download : Bool := false) : IO (List Project) :=
List.uniq Project.name <$> List.join <$>
  sequence (resolveDepsAux conf.depsDir download conf.name <$> conf.deps)

def getLeanPathFromDeps (depsDir : String) (xs : List Project) : IO (List Pkg) :=
let getSourcesDir : Project → String :=
λ conf ⇒ [ ".", depsDir, conf.name, "src" ].joinPath;
let getPkg : Project → IO Pkg :=
λ conf ⇒ (Pkg.mk conf.name) <$> IO.realPath (getSourcesDir conf);
List.mapM getPkg xs

def getDepBinaryPath (depsDir : String) (conf : Project) : String :=
[ ".", depsDir, conf.name, conf.getBinary ].joinPath

def getCppLibraries (conf : Project) : List String :=
String.append "-l" <$> conf.cppLibs

def evalDep {α : Type} (depsDir : String) (conf : Project)
  (action : IO α) : IO α := do
  cwd ← IO.realPath ".";
  let path := [ depsDir, conf.name ].joinPath;
  exitv ← IO.chdir path;
  let errString := "cannot go to " ++ path;
  IO.cond (exitv ≠ 0) (throw errString);
  val ← action; IO.chdir cwd;
  pure val

def buildAux (tools : Tools) (depsDir : String)
  (doneRef : IO.Ref (List String)) :
  Bool → List Project → IO Unit
| _, [] ⇒ pure ()
| needsRebuild', hd :: tl ⇒ do
  done ← doneRef.get;
  if done.notElem hd.name then do
    needsRebuild ← evalDep depsDir hd (do
      needsRebuild ← or needsRebuild' <$> not <$> IO.fileExists hd.getBinary;
      IO.cond needsRebuild (compileProject hd tools []);
      pure needsRebuild);

    doneRef.set (hd.name :: done);
    buildAux needsRebuild tl
  else buildAux needsRebuild' tl

def setLeanPath (conf : Project) : IO (List Project) := do
  deps ← resolveDeps conf;
  leanPath ← getLeanPathFromDeps conf.depsDir deps;
  List.forM addToLeanPath leanPath;
  pure deps

def build (tools : Tools) (conf : Project) : IO Unit := do
  deps ← setLeanPath conf;
  leanPath ← IO.getEnv "LEAN_PATH";
  IO.println leanPath;
  ref ← IO.mkRef [];
  buildAux tools conf.depsDir ref false deps;
  let libs :=
    Lean.deps ++
    List.join (getCppLibraries <$> deps) ++
    Lean.libraries tools.leanHome ++
    getDepBinaryPath conf.depsDir <$> deps;
  compileProject conf tools libs

def olean (tools : Tools) (conf : Project) : IO Unit := do
  IO.println ("Generate .olean for " ++ conf.name);
  List.forM (runCmdPretty "") (oleanCommands conf tools)

def recOlean (tools : Tools) (conf : Project) : IO Unit := do
  deps ← setLeanPath conf;
  List.forM (λ cur ⇒ evalDep conf.depsDir cur (olean tools cur)) deps;
  olean tools conf

def clean (conf : Project) : IO Unit := do
  conf ← readConf config;
  let buildFiles :=
  conf.getBinary :: List.join (Source.garbage <$> conf.files);
  forM' silentRemove buildFiles  

def cleanRec (conf : Project) : IO Unit := do
  deps ← resolveDeps conf;
  forM' (λ cur ⇒ evalDep conf.depsDir cur (clean cur)) deps;
  clean conf
