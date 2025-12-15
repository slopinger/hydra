project('hydra', 'cpp',
  version: files('version.txt'),
  license: 'GPL-3.0',
  default_options: [
    'debug=true',
    'optimization=2',
    'cpp_std=c++23',
  ],
)

lix_expr_dep = dependency('lix-expr', required: true)
lix_main_dep = dependency('lix-main', required: true)
lix_store_dep = dependency('lix-store', required: true)

# Lix/Nix need extra flags not provided in its pkg-config files.
lix_dep = declare_dependency(
  dependencies: [
    lix_expr_dep,
    lix_main_dep,
    lix_store_dep,
  ],
  compile_args: ['-include', 'lix/config.h'],
)

pqxx_dep = dependency('libpqxx', required: true)

prom_cpp_core_dep = dependency('prometheus-cpp-core', required: true)
prom_cpp_pull_dep = dependency('prometheus-cpp-pull', required: true)

mdbook = find_program('mdbook', native: true)
perl = find_program('perl', native: true)

subdir('doc/manual')
subdir('nixos-modules')
subdir('src')
subdir('t')
