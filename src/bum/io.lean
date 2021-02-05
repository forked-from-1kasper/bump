import Init.System.FilePath
import bum.configconverter

open IO.Process

def Lean.deps := [ "-ldl", "-lgmp", "-Wl,--end-group", "-lLean",
                   "-lStd", "-lInit", "-lleancpp", "-Wl,--start-group" ]

def Lean.cppOptions := [ "-no-pie", "-pthread", "-Wno-unused-command-line-argument" ]

def config := "bum.config"

def runCmdPretty (proc : SpawnArgs) (s : Option String := none) : IO Unit := do
  let info := s.getD ""

  match proc.cwd with
  | some cwd => println! ">>> {cwd}"
  | none => pure ()
  println! "==> {proc.cmd} {proc.args.toList.space} {info}"

  let child ← spawn proc
  let exitCode ← child.wait

  if exitCode ≠ 0 then
    s! "process “{proc.cmd}” exited with code {exitCode}"
    |> IO.userError |> throw

  pure ()

def sourceOlean (tools : Tools) : Source → Option (List SpawnArgs)
| src@(Source.lean path) =>
  some [ { cmd := tools.lean, args := #["-o", src.asOlean, src.path] } ]
| _ => none

def getInclude (tools : Tools) : Array String :=
#["-I" ++ [ tools.leanHome, "include" ].joinPath]

def sourceCommands (tools : Tools) : Source → List SpawnArgs
| src@(Source.lean path) =>
  [ -- generate olean
    { cmd  := tools.lean, args := #["-o", src.asOlean, src.path] },
    -- compile into .cpp
    { cmd  := tools.lean,
      args := #["-c", ["..", src.asCpp].joinPath, ["..", src.path].joinPath]
      cwd  := [".", "src"].joinPath },
    -- emit .o
    { cmd  := tools.cpp,
      args := getInclude tools ++ #["-c", src.asCpp, "-o", src.obj] } ]
| src@(Source.cpp path) =>
  [ { cmd := tools.cpp,
      args := getInclude tools ++ #["-c", src.path, "-o", src.obj] } ]

def sourceLink (output : String) (tools : Tools)
  (files : List Source) (flags : List String) : List SpawnArgs :=
[ { cmd := tools.ar,
    args := #["rvs", output] ++ Array.map Source.obj files.toArray ++
            flags.toArray } ]

def sourceCompile (output : String) (tools : Tools)
  (files : List Source) (libs flags : List String) : List SpawnArgs :=
[ { cmd := tools.cpp,
    args := Lean.cppOptions.toArray ++ #["-o", output] ++
            (List.map Source.obj files).reverse.toArray ++
            libs.reverse.toArray ++ flags.toArray ++
            #["-L" ++ tools.leanHome ++ "/lib/lean"] } ]

def compileCommands (conf : Project) (tools : Tools)
  (libs flags : List String) : List SpawnArgs :=
match conf.build with
| BuildType.executable =>
  List.join (List.map (sourceCommands tools) conf.files) ++
  sourceCompile conf.getBinary tools conf.files libs flags
| BuildType.library =>
  List.join (List.map (sourceCommands tools) conf.files) ++
  sourceLink conf.getBinary tools conf.files flags

def oleanCommands (conf : Project) (tools : Tools) :=
List.join (List.filterMap (sourceOlean tools) conf.files)

def procents {α : Type} (xs : List α) : List (Nat × α) :=
List.map (λ (p : Nat × α) => (p.1 * 100 / xs.length, p.2)) xs.enum

def compileProject (conf : Project) (tools : Tools) (libs : List String) : IO Unit :=
let runPretty := λ p => runCmdPretty p.2 (some s!"({p.1} %)");
let actions := List.map runPretty
  (procents $ compileCommands conf tools libs conf.cppFlags);
IO.println ("Compiling " ++ conf.name) >> List.forM id actions

def silentRemove (filename : String) : IO Unit :=
IO.remove filename >>= λ _ => pure ()

structure Pkg :=
(name path : String)

def String.addToPath (dest delta : String) :=
match dest with
| "" => delta
| _  => dest ++ ":" ++ delta

def addToLeanPath (u : String) : IO Unit := do
  let path ← IO.getEnv "LEAN_PATH";
  match path with
  | none   => IO.setEnv "LEAN_PATH" u
  | some v => IO.setEnv "LEAN_PATH" (v.addToPath u);
  pure ()

abbrev Path := String
abbrev Deps := List (Path × Project)

partial def resolveDepsAux (depsDir : String) (download : Bool) :
  String → Dep → IO Deps
| parent, dep => do
  let confPath := [ depsDir, dep.name, config ].joinPath;

  let isThere ← IO.fileExists confPath;
  if (¬isThere ∧ download) then {
    IO.println ("==> downloading " ++ dep.name ++ " (of " ++ parent ++ ")");
    runCmdPretty (Dep.cmd depsDir dep)
  }

  let conf ← readConf confPath;
  let projects ← sequence (List.map (resolveDepsAux depsDir download dep.name) conf.deps);
  pure (List.join projects ++ [ (dep.name, conf) ])

def resolveDeps (conf : Project) (download : Bool := false) : IO Deps :=
List.uniq (Project.name ∘ Prod.snd) <$> List.join <$>
  List.mapM (resolveDepsAux conf.depsDir download conf.name) conf.deps

def getLeanPathFromDeps (depsDir : String) (xs : Deps) : IO (List String) :=
let getSourcesDir : Path → String :=
λ path => [ ".", depsDir, path, "src" ].joinPath;
let getPkg : Path × Project → IO String :=
λ ⟨path, conf⟩ => IO.realPath (getSourcesDir path);
List.mapM getPkg xs

def getDepBinaryPath (depsDir : String) (conf : Path × Project) : String :=
[ ".", depsDir, conf.fst, conf.snd.getBinary ].joinPath

def getCppLibraries (conf : Path × Project) : List String :=
List.map (String.append "-l") conf.snd.cppLibs

def evalDep {α : Type} (depsDir : String) (rel : Path)
  (action : IO α) : IO α := do
  let cwd ← IO.realPath ".";
  let path := [ depsDir, rel ].joinPath;

  let exitv ← IO.chdir path;
  unless (exitv = 0) do {
    throw (IO.Error.userError s!"cannot chdir to {path}")
  }

  let val ← action;
  let _ ← IO.chdir cwd;
  pure val

def buildAux (tools : Tools) (depsDir : String)
  (doneRef : IO.Ref (List String)) :
  Bool → Deps → IO Unit
| _, [] => pure ()
| needsRebuild', hd :: tl => do
  let done ← doneRef.get;
  if done.notElem hd.snd.name then do
    let needsRebuild ← evalDep depsDir hd.fst (do
      let needsRebuild ← or needsRebuild' <$> not <$> IO.fileExists hd.snd.getBinary;
      if needsRebuild then { compileProject hd.snd tools [] }
      pure needsRebuild);

    doneRef.set (hd.snd.name :: done);
    buildAux tools depsDir doneRef needsRebuild tl
  else buildAux tools depsDir doneRef needsRebuild' tl

def setLeanPath (conf : Project) : IO Deps := do
  let deps ← resolveDeps conf;
  let leanPath ← getLeanPathFromDeps conf.depsDir deps;
  List.forM addToLeanPath leanPath;
  pure deps

def build (tools : Tools) (conf : Project) : IO Unit := do
  let deps ← setLeanPath conf;
  let ref ← IO.mkRef [];
  buildAux tools conf.depsDir ref false deps;
  let libs :=
    Lean.deps ++
    List.join (List.map getCppLibraries deps) ++
    List.map (getDepBinaryPath conf.depsDir) deps;
  compileProject conf tools libs

def olean (tools : Tools) (conf : Project) : IO Unit := do
  IO.println ("Generate .olean for " ++ conf.name);
  List.forM runCmdPretty (oleanCommands conf tools)

def recOlean (tools : Tools) (conf : Project) : IO Unit := do
  let deps ← setLeanPath conf;
  List.forM
    (λ (cur : Path × Project) =>
      evalDep conf.depsDir cur.fst (olean tools cur.snd))
    deps;
  olean tools conf

def clean (conf : Project) : IO Unit := do
  let conf ← readConf config;
  let buildFiles :=
  conf.getBinary :: List.join (List.map Source.garbage conf.files);
  List.forM silentRemove buildFiles  

def cleanRec (conf : Project) : IO Unit := do
  let deps ← resolveDeps conf;
  List.forM
    (λ (cur : Path × Project) =>
      evalDep conf.depsDir cur.fst (clean cur.snd))
    deps;
  clean conf
