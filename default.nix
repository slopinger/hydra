# The `default.nix` in flake-compat reads `flake.nix` and `flake.lock` from `src` and
# returns an attribute set of the shape `{ defaultNix, shellNix }`

(import (
  let
    inherit (lock.nodes.flake-compat.locked) narHash rev;
    lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  in
  fetchTarball {
    url = "https://github.com/nix-community/flake-compat/archive/${rev}.tar.gz";
    sha256 = narHash;
  }
) { src = ./.; }).defaultNix
