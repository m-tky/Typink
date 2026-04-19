#!/usr/bin/env zsh
nix-shell shell.nix --run "cd flutter_app && export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$(pwd)/rust/target/debug; flutter run -d linux" & disown
