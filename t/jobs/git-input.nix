with import ./config.nix;
{ src }:
assert src?lastModified && src?lastModifiedDate;
{
  copy =
    mkDerivation {
      name = "git-input";
      builder = ./scm-builder.sh;
      inherit src;
    };
}
