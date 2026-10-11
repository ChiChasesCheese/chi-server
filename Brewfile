# brew bundle --file=Brewfile   (run by `chi bootstrap brew`)
# Only what the server really needs. Container runtime / Tailscale / Ollama are installed separately
# by bootstrap, based on .env.

brew "git"
brew "jq"          # parse JSON in scripts (tailscale status etc.)
brew "restic"      # backups: incremental, deduplicated, encrypted; local disk / B2 / S3
brew "btop"        # real host CPU / memory / temps (containers only see the VM)
brew "mas"         # install/update App Store apps from the CLI (optional)

# Optional: uncomment when needed
# cask "utm"       # run a Home Assistant OS VM (see docs/roadmap.md)
# brew "cloudflared"  # expose individual services publicly (see docs/remote-access.md)
