# Legacy Hydra jobset: use this repository as `src`, a nixpkgs checkout as
# `nixpkgs`, and change the string input `run` to start a fresh batch.
{
  nixpkgs,
  run ? "demo",
  ...
}:
let
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  progress = name: seconds: fail: dependencies:
    pkgs.runCommand "live-demo-${name}" {
      inherit run dependencies;
      preferLocalBuild = true;
      allowSubstitutes = false;
      meta.description = "Live UI demo: ${name} (${toString seconds} seconds)";
    } ''
      echo "Demo: ${name}; batch: $run"
      echo "Printing progress every two seconds for ${toString seconds} seconds."
      ${pkgs.lib.optionalString (dependencies != []) ''
        echo "Dependency completed: $dependencies"
      ''}
      for ((elapsed=0; elapsed<${toString seconds}; elapsed+=2)); do
        printf '[%s] ${name}: %d / ${toString seconds} seconds\n' "$(date -u +%H:%M:%S)" "$elapsed"
        sleep 2
      done
      ${if fail then ''
        echo "Intentional demo failure: this red build is expected." >&2
        exit 1
      '' else ''
        mkdir -p "$out"
        printf 'Completed ${name}, batch %s\n' "$run" > "$out/result"
        echo "Success: ${name} completed."
      ''}
    '';
  quick = progress "quick-success" 30 false [];
in
{
  quick-success = quick;
  steady-success = progress "steady-success" 180 false [];
  long-success = progress "long-success" 600 false [];
  expected-failure = progress "expected-failure" 90 true [];
  after-success = progress "after-success" 30 false [quick];
}
