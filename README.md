# supersearchr
v 0.1.0

Supersearchr was born out of my necessity to have a way to search torrents that integrated with Superseedr in the terminal.

Supersearchr is a Linux-only-guaranteed (actually not sure if it would be cross-platform) TUI BitTorrent search tool written in Zig. It searches via Jackett and sends selected magnet or torrent links to Superseedr. This project uses Zig 0.15.2.

## Build and Test

> [!NOTE]
> This app has no other dependency than the Zig standard library

Build:
```bash
zig build
```

Build a Linux executable:
```bash
zig build -Dtarget=x86_64-linux
```

Run (from project folder):
```bash
zig build run
```

Run (compiled executable):
```bash
./zig-out/bin/supersearchr
```
or if the binary is in your `PATH`:
```bash
supersearchr
```

Tests (detailed output):
```bash
zig build test --summary all
```

Install (typical):
After building, copy the binary to a directory in your `PATH`, such as `~/.local/bin` or `/usr/local/bin`. If you are unsure, follow your Linux distribution's documentation for the conventional way to install user executables.

## Configuration

On first run, the app creates a default config file at `~/.config/supersearchr/config.json` and then prompts you to fill in the required variables. The app will not run until the default Jackett URL and API key values are replaced.

The config includes:
- Jackett URL, port and API key
- The executable of the terminal app you wish to use (default: ghostty)

## Usage (Search and Download)

1. Type your search query and press Enter.
2. Use j/k or J/K keys to navigate results.
3. Press Enter to select a result and send it to Superseedr. If Superseedr is not running, a new terminal instance will be spawned with superseedr running on it.
4. You can either select one or more torrents from the same result list, press n to make a new search, or press ESC to exit the application.
