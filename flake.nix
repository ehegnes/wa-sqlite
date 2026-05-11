{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      treefmt-nix,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      imports = [
        treefmt-nix.flakeModule
      ];
      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        let
          nodejs = pkgs.nodejs_24;
          pnpm = pkgs.pnpm_10;
          buildPnpmPackage = import ./nix/buildPnpmPackage.nix {
            inherit pkgs nodejs pnpm;
          };
          treefmt = treefmt-nix.lib.evalModule pkgs (import ./nix/treefmt.nix { inherit pkgs; });
          sqliteVersion = "3.53.0";
          sqliteTarball = pkgs.fetchurl {
            url = "https://www.sqlite.org/src/tarball/version-${sqliteVersion}/sqlite.tar.gz";
            hash = "sha256-Des+/VDpZx9TJaIpgOAqfU6ISJH9eO+RUEoGfGyy9fM=";
          };
          extensionFunctions = pkgs.fetchurl {
            url = "https://www.sqlite.org/contrib/download/extension-functions.c?get=25";
            name = "extension-functions.c";
            hash = "sha256-mRtA/osnme3CFfcmC4kPFKgzUSydmJaqCAiRMw/+QFI=";
          };
          sqlite = pkgs.stdenv.mkDerivation {
            pname = "sqlite";
            version = sqliteVersion;
            src = sqliteTarball;

            nativeBuildInputs = [ pkgs.tcl ];

            configurePhase = ''
              runHook preConfigure
              ./configure --enable-all
              runHook postConfigure
            '';

            buildPhase = ''
              runHook preBuild
              make sqlite3.c
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp sqlite3.c sqlite3.h sqlite3ext.h $out/
              runHook postInstall
            '';
          };
        in
        {
          formatter = treefmt.config.build.wrapper;
          checks = {
            formatting = treefmt.config.build.check self;
          };
          packages = {
            wa-sqlite-dist = pkgs.buildEmscriptenPackage {
              pname = "wa-sqlite";
              version = "0.0.0";
              src = pkgs.lib.fileset.toSource {
                root = ./.;
                fileset = ./src;
              };

              dontStrip = true;
              dontConfigure = true;
              dontInstall = true;

              buildPhase = ''
                runHook preBuild

                export HOME=$TMPDIR
                export EM_CACHE=$TMPDIR/.emscripten_cache
                mkdir -p $out

                cflags=(
                  -Oz -flto
                  -I ${sqlite}
                  -Wno-non-literal-null-conversion
                  -DSQLITE_EXPERIMENTAL_PRAGMA_20251114
                  -DSQLITE_DEFAULT_MEMSTATUS=0
                  -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1
                  -DSQLITE_DQS=0
                  -DSQLITE_LIKE_DOESNT_MATCH_BLOBS
                  -DSQLITE_MAX_EXPR_DEPTH=0
                  -DSQLITE_OMIT_AUTOINIT
                  -DSQLITE_OMIT_DECLTYPE
                  -DSQLITE_OMIT_DEPRECATED
                  -DSQLITE_OMIT_LOAD_EXTENSION
                  -DSQLITE_OMIT_SHARED_CACHE
                  -DSQLITE_THREADSAFE=0
                  -DSQLITE_USE_ALLOCA
                  -DSQLITE_ENABLE_BATCH_ATOMIC_WRITE
                )

                emflags=(
                  -s ALLOW_MEMORY_GROWTH=1
                  -s WASM=1
                  -s INVOKE_RUN
                  -s ENVIRONMENT=web,worker
                  -s STACK_SIZE=512KB
                  -s WASM_BIGINT=0
                  -s EXPORTED_FUNCTIONS=@src/exported_functions.json
                  -s EXPORTED_RUNTIME_METHODS=@src/extra_exported_runtime_methods.json
                  --js-library src/libadapters.js
                  --post-js   src/libauthorizer.js
                  --post-js   src/libfunction.js
                  --post-js   src/libhook.js
                  --post-js   src/libprogress.js
                  --post-js   src/libvfs.js
                )

                sources=(
                  ${sqlite}/sqlite3.c
                  ${extensionFunctions}
                  src/main.c
                  src/libauthorizer.c
                  src/libfunction.c
                  src/libhook.c
                  src/libprogress.c
                  src/libvfs.c
                )

                emcc "''${cflags[@]}" "''${emflags[@]}" \
                  "''${sources[@]}" -o $out/wa-sqlite.mjs

                emcc "''${cflags[@]}" "''${emflags[@]}" \
                  -s ASYNCIFY \
                  -s ASYNCIFY_IMPORTS=@src/asyncify_imports.json \
                  -s ASYNCIFY_STACK_SIZE=16384 \
                  "''${sources[@]}" -o $out/wa-sqlite-async.mjs

                emcc "''${cflags[@]}" "''${emflags[@]}" \
                  -s JSPI \
                  -s ASYNCIFY_IMPORTS=@src/asyncify_imports.json \
                  -s JSPI_EXPORTS=@src/jspi_exports.json \
                  "''${sources[@]}" -o $out/wa-sqlite-jspi.mjs

                runHook postBuild
              '';
              checkPhase = "";
            };
            wa-sqlite-pkg = buildPnpmPackage {
              packageJsonPath = ./package.json;
              extraSrcs = pkgs.lib.fileset.unions [ ./. ];
              hash = "sha256-JWbCxfRfkqNldP6YlAhU1Dg0QtBTNaXPWVyYvR3um5o=";
              doCheck = false;
              buildPhase = ''
                runHook preBuild
                mkdir -p dist
                cp -r ${config.packages.wa-sqlite-dist}/. ./dist/
                runHook postBuild
              '';
              installPhase = ''
                mkdir -p $out
                pnpm pack --pack-destination $out
              '';
              checkPhase = "";
            };
          };
          devShells.default = pkgs.mkShell {
            packages = [
              pnpm
              nodejs
              pkgs.emscripten
              pkgs.openssl
              pkgs.which
              pkgs.tcl
              pkgs.wabt
              pkgs.unzip
              pkgs.zip
              pkgs.nixd
              pkgs.nil
              pkgs.nixd
            ];
          };
        };
    };
}
