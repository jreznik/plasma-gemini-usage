# 🚀 Gemini Usage Monitor & Session Telemetry

A state-of-the-art KDE Plasma 6 widget and telemetry companion that stealthily monitors your Google Gemini rolling 5-hour usage capacity and weekly budget directly on your Linux desktop or panel. It features robust multilingual scraping, network-aware auto-refresh, and a detailed session analytics dashboard.

---

## 🌟 Key Features

*   **Real-time Desktop Widget:** Premium-styled panel and desktop widget with harmonized dark/light theme colors, glassmorphic layout, and Kirigami animations.
*   **Puppeteer Stealth Scraper (`get_usage.js`):** High-fidelity Puppeteer scraper utilizing advanced fingerprint masking, client-hints sync, and human-mouse scroll emulation to evade Google bot-detection.
*   **Multilingual Date Engine:** Natively parses dates, accents, and punctuation marks in English, Czech, German, French, Spanish, Portuguese, and Italian.
*   **Redirect-Loop Prevention:** Bulletproof request interceptor that limits cookie injections strictly to `gemini.google.com`, cleanly reporting `auth_error` when credentials expire.
*   **Network-Aware Sync:** Automatically detects laptop awake states and network reconnection triggers via native Plasma network bindings to refresh statistics immediately.
*   **Session Telemetry Companion (`query_session_usage.py`):** Programmatic Python tool that parses Antigravity conversation logs, providing a beautiful HSL-bar console dashboard of your context window consumption (User Prompts, Agent Reasonings, Tool Outputs).

---

## 📦 System Dependencies Installation

The scraper requires **Node.js** (v16+) and a Chromium-based browser (Chrome, Chromium, Brave, or Edge). 

Installing your distribution's standard Chromium/Chrome package is the recommended approach, as it automatically pulls in all required system graphic, font, and audio libraries (like `nss`, `atk`, `gbm`, and `xcomposite`) required for headless execution.

### 🔵 Fedora / RHEL / CentOS
1.  **Install Node.js, npm, and Python:**
    ```bash
    sudo dnf install nodejs npm python3
    ```
2.  **Install Chromium (recommended for pulling in all headless rendering libraries):**
    ```bash
    sudo dnf install chromium
    ```
3.  **Alternative (Google Chrome Stable):**
    If you prefer Google Chrome:
    ```bash
    sudo dnf config-manager --set-enabled google-chrome
    sudo dnf install google-chrome-stable
    ```
4.  **Minimal/Server Headless Dependencies:**
    If you are running a minimal or headless Fedora setup and encounter shared-library issues, install these graphics libraries:
    ```bash
    sudo dnf install alsa-lib atk cups-libs gtk3 libXcomposite libXcursor libXdamage libXext libXfixes libXi libXrandr libXrender libXtst libxcb libxshmfence nss pango mesa-libgbm
    ```

### 🟠 Ubuntu / Debian / Linux Mint
1.  **Install Node.js, npm, and Python:**
    ```bash
    sudo apt update
    sudo apt install nodejs npm python3
    ```
2.  **Install Chromium:**
    ```bash
    sudo apt install chromium-browser
    ```
3.  **Minimal/Server Headless Dependencies:**
    ```bash
    sudo apt install libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libxcomposite1 libxdamage1 libxrandr2 libgbm1 libxkbcommon0 libpango-1.0-0 libasound2
    ```

### 🔴 Arch Linux
1.  **Install Node.js, npm, Python, and Chromium:**
    ```bash
    sudo pacman -S nodejs npm python3 chromium
    ```

---

## 🔧 Installation & Project Setup

### 1. Install Node Dependencies
Navigate to the project workspace and install the required npm dependencies (`puppeteer-core` for the browser scraper):
```bash
cd /home/jreznik/gemini/plasma-gemini-usage
npm install
```

### 2. Register the Plasmoid with KDE Plasma 6
Install the widget to your local user directory:
```bash
kpackagetool6 -i . -t Plasma/Applet
```
*Note: If updating an existing installation, use:*
```bash
kpackagetool6 -u . -t Plasma/Applet
```

Alternatively, copy the files directly to your Plasmoids directory:
```bash
mkdir -p ~/.local/share/plasma/plasmoids/org.kde.plasma.geminiusage
cp -r * ~/.local/share/plasma/plasmoids/org.kde.plasma.geminiusage/
```

### 3. Restart Plasma Shell to Load
Restart the desktop environment to load the widget instantly:
```bash
plasmashell --replace &
```

---

## 🚀 Usage

### Desktop Widget Configuration
1.  Add the **"Gemini Usage Monitor"** widget to your panel or desktop.
2.  Right-click and select **"Configure Gemini Usage Monitor..."**.
3.  Click **"Launch Sign-in Browser"** to log in to your Google Account. 
4.  Once successfully authenticated, close the browser. The scraper will automatically extract your active cookies, securely write them to `~/.config/plasma-gemini-usage/config.json`, and refresh your statistics.

### Programmatic Scraper Manual Run
You can run the scraper from the command line to fetch fresh JSON output or diagnose connection states:
```bash
node get_usage.js
```
**Example output:**
```json
{
  "status": "success",
  "five_hour_pct": 12,
  "weekly_pct": 3,
  "countdown": "Active",
  "five_hour_reset_epoch": 1779491940,
  "weekly_reset_epoch": 1779779940,
  "five_hour_reset_str": "Resets at 1:19 AM",
  "weekly_reset_str": "Resets May 26 at 9:19 AM",
  "timestamp": 1779478029
}
```

### Session Telemetry & Context Dashboard
To inspect your active Antigravity conversation telemetry (tokens consumed, remaining, and category breakdowns):
```bash
# Standard console dashboard
python3 query_session_usage.py

# Programmatic raw JSON output
python3 query_session_usage.py --json
```

---

## 📂 Configuration Paths
*   **Config Folder:** `~/.config/plasma-gemini-usage/`
*   **Active Session Cache:** `~/.config/plasma-gemini-usage/cache.json`
*   **Session Credentials:** `~/.config/plasma-gemini-usage/config.json`
*   **Puppeteer Execution Logs:** `~/.config/plasma-gemini-usage/puppeteer.log`

---

## 📄 License
This project is licensed under the GPL-2.0-or-later License - see the `metadata.json` for details.
