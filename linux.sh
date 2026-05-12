#!/usr/bin/env zsh
nix develop -c sh -c "cd flutter_app && flutter run -d linux" & disown
