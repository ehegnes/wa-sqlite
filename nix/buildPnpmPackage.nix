{
  pnpm,
  nodejs,
  pkgs,
  ...
}:
args@{
  packageJsonPath,
  extraSrcs,
  pnpmWorkspaces ? [ ],
  hash ? pkgs.lib.fakeHash,
  ...
}:

let
  fs = pkgs.lib.fileset;
  src = fs.toSource {
    root = ./..;
    fileset = fs.union extraSrcs (
      fs.unions [
        ../package.json
        ../pnpm-lock.yaml
      ]
    );
  };
  packageJson = pkgs.lib.importJSON packageJsonPath;
  pname = packageJson.name;
  inherit (packageJson) version;
  pnpmDeps = pnpm.fetchDeps {
    inherit
      hash
      pname
      pnpmWorkspaces
      src
      version
      ;
    fetcherVersion = 3;
  };
in
pkgs.buildNpmPackage (
  (removeAttrs args [ "extraSrcs" ])
  // rec {
    inherit
      pname
      pnpmDeps
      pnpmWorkspaces
      src
      version
      nodejs
      ;
    npmConfigHook = pnpm.configHook;
    npmDeps = pnpmDeps;
  }
)
