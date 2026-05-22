# Gemini Usage Monitor & Session Telemetry

A KDE Plasma 6 widget and diagnostic tool that tracks your Google Gemini rolling 5-hour usage limits and weekly budget.

*Developed with the assistance of the Antigravity CLI.*

---

## Features

* **KDE Plasma 6 Widget:** Displays rolling 5-hour limit and weekly budget directly on your desktop or panel. Automatically adapts its layout for panel placement (compact ring) and desktop placement (full view).
* **Automated Scraper (`get_usage.js`):** A Node.js Puppeteer script that signs in and extracts usage metrics from `gemini.google.com`.
* **Multilingual support:** Date and number extraction handles localized dates in English, Czech, German, French, Spanish, Portuguese, and Italian.
* **Network-Aware:** Auto-refreshes when waking up from suspend or when a network connection is re-established.
* **Context Telemetry Companion (`query_session_usage.py`):** A command-line script to inspect the token consumption and reasoning details of your local Antigravity conversation transcripts.

---

## Installation & Prerequisites

To run the scraper, you need **Node.js** (v16+) and a Chromium-based browser (Chrome, Chromium, Brave, or Microsoft Edge). Installing Chrome/Chromium via your system package manager is recommended as it pulls in all necessary system libraries (e.g. `nss`, `atk`, `gbm`, `xcomposite`) automatically.

### Fedora (Recommended)

1. Install Node.js, npm, and Python:
   ```bash
   sudo dnf install nodejs npm python3
   ```

2. Install Chromium (recommended for system libraries):
   ```bash
   sudo dnf install chromium
   ```
   Or if you prefer Google Chrome:
   ```bash
   sudo dnf config-manager --set-enabled google-chrome
   sudo dnf install google-chrome-stable
   ```

### Ubuntu / Debian

1. Install Node.js, npm, and Python:
   ```bash
   sudo apt update
   sudo apt install nodejs npm python3
   ```

2. Install Chromium:
   ```bash
   sudo apt install chromium-browser
   ```

### Arch Linux

1. Install Node.js, npm, Python, and Chromium:
   ```bash
   sudo pacman -S nodejs npm python3 chromium
   ```

---

## Getting Started

### 1. Install Node.js dependencies
Run this inside the widget root directory:
```bash
npm install
```

### 2. Register the Plasmoid
Install the widget to your local Plasma applets directory:
```bash
kpackagetool6 -i . -t Plasma/Applet
```
If you are upgrading an existing installation:
```bash
kpackagetool6 -u . -t Plasma/Applet
```

### 3. Reload Plasma Shell
To make the widget visible immediately:
```bash
plasmashell --replace &
```

---

## Usage

### 1. Widget Configuration & Sign-in
1. Add **"Gemini Usage Monitor"** to your desktop or panel.
2. Right-click and choose **"Configure Gemini Usage Monitor..."**.
3. Click **"Launch Sign-in Browser"** and log in to your Google Account.
4. Close the browser once signed in. The widget will automatically extract the session cookies, save them to `~/.config/plasma-gemini-usage/config.json`, and run the scraper.

### 2. Running the Scraper Manually
You can run the script manually to verify it works or check raw JSON data:
```bash
node get_usage.js
```

### 3. Conversation Telemetry CLI
To see your token consumption metrics:
```bash
python3 query_session_usage.py
```
Or export raw stats as JSON:
```bash
python3 query_session_usage.py --json
```

---

## File and Config Paths

* **Config Directory:** `~/.config/plasma-gemini-usage/`
* **Session Credentials:** `~/.config/plasma-gemini-usage/config.json`
* **Cache File:** `~/.config/plasma-gemini-usage/cache.json`
* **Puppeteer Log:** `~/.config/plasma-gemini-usage/puppeteer.log`

---

## License

This project is licensed under the GPL-3.0-or-later License. See `metadata.json` and the `LICENSE` file for details.
