# Flumen for macOS

![Status](https://img.shields.io/badge/status-stable-green)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![License](https://img.shields.io/badge/license-Non--Commercial-red)

A beautiful, free focus timer for macOS. Lives in your menu bar, stores data locally, and stays out of your way. No bloat, no paywalls, no cloud.

![Flumen for macOS](docs/assets/banner.png)

---

## Download

### [Download Latest Release (.zip)](https://github.com/saranshbarua/flumen/releases/latest/download/Flumen_macOS_Universal.zip)

To install and run the app:
1. Download the `Flumen_macOS_Universal.zip` from the link above.
2. Unzip the file and move `Flumen.app` to your **Applications** folder.
3. Open `Flumen.app`. macOS will say it can't verify the app. Click **Done**.
4. Open **System Settings** > **Privacy & Security**, scroll down to **Security**, and click **Open Anyway** next to the Flumen message. The button stays there for about an hour after you try to open the app.
5. Click **Open** in the dialog that follows and enter your login password.

You only need to do this once, because Flumen is currently ad-hoc signed and not notarized by Apple. After that, it opens normally.

> [!NOTE]
> **On macOS 13 Ventura or 14 Sonoma**, you can instead **Control-click** (or right-click) `Flumen.app` in Finder, choose **Open**, then click **Open** again. Apple removed this shortcut in macOS 15 Sequoia.

---

## Features

### Native macOS Presence
- **Menu Bar Companion**: Mirror your remaining time directly in the macOS menu bar for glanceable tracking.
- **Floating Popup**: Popover-style interface that stays on top when you need it without stealing focus.
- **Global Shortcuts**: Toggle visibility from anywhere with `⌥⇧P` (Option+Shift+P).
- **Space-Aware**: The timer follows you across Mission Control spaces automatically.

### Integrated Analytics & Tasks
- **Task Focused**: A slide-up "Task Shelf" to manage your session goals without distraction.
- **Project Tagging**: Categorize your focus sessions with project-level tags to see where your time goes.
- **Deep Insights**: Detailed bar charts, project distribution lists, and streak tracking.
- **CSV Export**: Export your focus data to CSV for external analysis.
- **Native Persistence**: Your logs and tasks are saved to a native SQLite database, surviving updates and restarts.
- **Automatic Logging**: Focus time is logged automatically every minute and on session completion.

---

## Visual Showcase

| Focus Mode | Task Shelf | Reports & Insights |
| :---: | :---: | :---: |
| ![Main Timer](docs/assets/main-timer.png) | ![Task Shelf](docs/assets/task-shelf.png) | ![Reports](docs/assets/analytics-report-1.png) |

| Long Break | Short Break | Settings |
| :---: | :---: | :---: |
| ![Long Break](docs/assets/long-break.png) | ![Short Break](docs/assets/short-break.png) | ![Settings](docs/assets/settings.png) |

---

## Tech Stack

- **Frontend**: [React 19](https://react.dev/), [TypeScript](https://www.typescriptlang.org/), [Zustand](https://github.com/pmndrs/zustand), [Recharts](https://recharts.org/).
- **Native Wrapper**: [Swift](https://developer.apple.com/swift/), AppKit, WKWebView.
- **Communication**: Custom JS-to-Swift bridge using `WKScriptMessageHandler`.
- **Testing**: [Vitest](https://vitest.dev/), React Testing Library.

---

## Build from Source

### Prerequisites
- macOS 13+ (Ventura or later)
- [Node.js](https://nodejs.org/) & npm
- Xcode Command Line Tools (`xcode-select --install`)

### Development Steps
1. **Clone the repository**:
   ```bash
   git clone https://github.com/saranshbarua/flumen.git
   cd flumen
   ```
2. **Install Dependencies**:
   ```bash
   npm install
   ```
3. **Build the Universal Binary**:
   ```bash
   sh build_app.sh
   ```
   This will generate `Flumen.app` and a distribution ZIP in the project root.

---

## Documentation

Explore the technical details:
- [Roadmap](docs/ROADMAP.md) - Future features and improvements.
- [Architecture](docs/CODEBASE.md) - Deep dive into the hybrid bridge.
- [Full Feature List](docs/FEATURES.md) - Detailed breakdown of capabilities.
- [Testing Strategy](docs/TESTING.md) - Our approach to quality.

---

## Contributing

We welcome contributions! Whether you're fixing a bug, suggesting a feature, or improving documentation, we appreciate your help. Please see our [CONTRIBUTING.md](CONTRIBUTING.md) for:
- **Conventional Commits**: We follow strict commit naming conventions.
- **Development Workflow**: How to set up and run the project locally.
- **Testing**: How to run our Vitest suite.
- **Release Process**: How we automate builds and deployments.

## License

This project is licensed under a custom **Non-Commercial Share-Alike** license. It is free for personal use and internal work productivity, but selling the software or redistributing it for commercial gain is strictly prohibited. Any modifications must also be shared under the same terms. See the [LICENSE](LICENSE) file for the full legal text.

---

Built for deep thinkers.
