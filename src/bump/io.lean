import init.system.io init.system.filepath
import bump.configconverter

def Lean.deps := [ "-lpthread", "-lgmp" ]
def Lean.libraries (leanHome : String) := 
List.joinPath <$>
  [ [ leanHome, "bin", "libleanstatic.a" ],
    [ leanHome, "bin", "libleanstdlib.a" ] ]
def Lean.cppOptions := [ "-fPIC", "-Wno-unused-command-line-argument" ]

def config := "bump.config"

def runCmdPretty (s additionalInfo : String) : IO Unit := do
  IO.println ("==> " ++ s ++ " " ++ additionalInfo);
  exitv ← IO.runCmd s;
  let errorStr := "process exited with code " ++ toString exitv;
  IO.cond (exitv ≠ 0) (throw errorStr)

def sourceCommands (tools : Tools) : Source → List String
| src@(Source.lean path) ⇒
  List.space <$>
    [ [ tools.lean, "--make", src.path ],
      [ tools.lean, "-c", src.asCpp, src.path ],
      [ tools.leanc, "-c", src.asCpp, "-o", src.obj ] ]
| src@(Source.cpp path) ⇒
  List.space <$>
    [ [ tools.leanc, "-c", src.path, "-o", src.obj ] ]

def sourceLink (output : String) (tools : Tools) (files : List Source) :=
List.space $ [ tools.ar, "rvs", output ] ++ Source.obj <$> files

def sourceCompile (output : String) (tools : Tools)
  (files : List Source) (libs : List String) :=
List.space $
  pure tools.cpp ++ Lean.cppOptions ++
  [ "-o",  output ] ++
  (Source.obj <$> files).reverse ++
  libs.reverse

def compileCommands (conf : Project) (tools : Tools) (libs : List String) :=
match conf.build with
| BuildType.executable ⇒
  List.join (sourceCommands tools <$> conf.files) ++
  [ sourceCompile conf.getBinary tools conf.files libs ]
| BuildType.library ⇒
  List.join (sourceCommands tools <$> conf.files) ++
  [ sourceLink conf.getBinary tools conf.files ]

def procents {α : Type} (xs : List α) : List (Nat × α) :=
(λ (p : Nat × α) ⇒ (p.1 * 100 / xs.length, p.2)) <$> xs.enum

def compileProject (conf : Project) (tools : Tools) (libs : List String) : IO Unit :=
let runPretty :=
λ (p : Nat × String) ⇒ runCmdPretty p.2 ("(" ++ toString p.1 ++ " %)");
let actions := runPretty <$> procents (compileCommands conf tools libs);
IO.println ("Compiling " ++ conf.name) >> forM' id actions

def silentRemove (filename : String) : IO Unit :=
do IO.remove filename; pure ()

def addToLeanPath : String → IO Unit
| "" ⇒ pure ()
| dirpath ⇒ do
  path ← IO.getEnv "LEAN_PATH";
  match path with
  | some v ⇒ IO.setEnv "LEAN_PATH" (v ++ ":" ++ dirpath)
  | none ⇒ IO.setEnv "LEAN_PATH" dirpath;
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

def getLeanPathFromDeps (depsDir : String) (xs : List Project) : IO String :=
let getSourcesDir : Project → String :=
λ conf ⇒ [ ".", depsDir, conf.name, "src" ].joinPath;
let dirs : List (IO String) := (IO.realPath ∘ getSourcesDir) <$> xs;
String.intercalate ":" <$> sequence dirs

def getDepBinaryPath (depsDir : String) (conf : Project) : String :=
[ ".", depsDir, conf.name, conf.getBinary ].joinPath

def getCppLibraries (conf : Project) : List String :=
String.append "-l" <$> conf.cppLibs

def buildAux (tools : Tools) (depsDir : String)
  (doneRef : IO.Ref (List String)) :
  Bool → List Project → IO Unit
| _, [] ⇒ pure ()
| needsRebuild', hd :: tl ⇒ do
  done ← doneRef.get;
  if done.notElem hd.name then do
    IO.chdir [depsDir, hd.name].joinPath;
    needsRebuild ← or needsRebuild' <$> not <$> IO.fileExists hd.getBinary;
    IO.cond needsRebuild (compileProject hd tools []);
    IO.chdir [ "..", ".." ].joinPath;
    doneRef.set (hd.name :: done);
    buildAux needsRebuild tl
  else buildAux needsRebuild' tl

def build (tools : Tools) (conf : Project) : IO Unit := do
  deps ← resolveDeps conf;
  getLeanPathFromDeps conf.depsDir deps >>= addToLeanPath;
  ref ← IO.mkRef [];
  buildAux tools conf.depsDir ref false deps;
  let libs :=
    Lean.deps ++
    List.join (getCppLibraries <$> deps) ++
    Lean.libraries tools.leanHome ++
    getDepBinaryPath conf.depsDir <$> deps;
  compileProject conf tools libs
