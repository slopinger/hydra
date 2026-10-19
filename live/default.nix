{ lib, python3, runCommand, writeShellApplication }:
let
  python = python3.withPackages (p: [ p.aiohttp p.asyncpg p.zstandard ]);
  tests = runCommand "hydra-live-tests" { nativeBuildInputs = [ python ]; } ''
    cp -r ${./.} live
    chmod -R u+w live
    cd live
    python -m unittest discover -v
    touch $out
  '';
in writeShellApplication {
  name = "hydra-live";
  text = ''exec ${python}/bin/python ${./server.py} "$@"'';
  passthru.tests = { inherit tests; };
  meta = {
    description = "Live build events and streaming logs for Hydra";
    license = lib.licenses.gpl3;
    mainProgram = "hydra-live";
  };
}
