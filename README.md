<a id="readme-top"></a>

<!-- PROJECT SHIELDS -->
[![Contributors][contributors-shield]][contributors-url]
[![Forks][forks-shield]][forks-url]
[![Stargazers][stars-shield]][stars-url]
[![Issues][issues-shield]][issues-url]
[![project_license][license-shield]][license-url]

<!-- PROJECT LOGO -->
<br />
<div align="center">
  <a href="https://github.com/sleimanzublidi/Vivarium">
    <img src="Sources/Vivarium/Resources/AppIcons/AppIcon256.png" alt="Vivarium" width="128" height="128">
  </a>

<h3 align="center">Vivarium</h3>

  <p align="center">
    A macOS desktop pet companion for Claude Code and GitHub Copilot CLI.
    <br />
    <a href="Docs/SPEC.md"><strong>Read the spec »</strong></a>
    <br />
    <br />
    <a href="https://github.com/sleimanzublidi/Vivarium/issues/new?labels=bug">Report Bug</a>
    &middot;
    <a href="https://github.com/sleimanzublidi/Vivarium/issues/new?labels=enhancement">Request Feature</a>
  </p>
</div>

<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#built-with">Built With</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#installation">Installation</a></li>
      </ul>
    </li>
    <li><a href="#usage">Usage</a></li>
    <li><a href="#roadmap">Roadmap</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
    <li><a href="#acknowledgments">Acknowledgments</a></li>
  </ol>
</details>

## About The Project

Vivarium is a small floating window — "the tank" — that sits on your desktop and shows one animated pet per active coding-agent session. The pet animates based on what its session is doing (running a tool, thinking, waiting for input, erroring out) and shows a speech-balloon message when something interesting happens.

It's a Swift + SpriteKit reimagining of [Clawd Tank](https://github.com/marciogranzotto/clawd-tank), using the [OpenPets](https://github.com/alvinunreal/openpets) pack format unchanged so community packs work without conversion.

Pets are assigned per project. When you `cd` into a different repo and start a session there, you get the pet you mapped to that project. The app runs as a menu bar item (`LSUIElement`); closing the window doesn't quit it, so background tracking keeps working as long as the app is alive.

For the architecture, event pipeline, state machine, and pack contract, see [Docs/SPEC.md](Docs/SPEC.md) and [Docs/State-Mapping.md](Docs/State-Mapping.md).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

### Built With

* [![Swift][Swift-shield]][Swift-url]
* [![macOS][macOS-shield]][macOS-url]
* [![SpriteKit][SpriteKit-shield]][SpriteKit-url]
* [![Xcode][Xcode-shield]][Xcode-url]
* [![XcodeGen][XcodeGen-shield]][XcodeGen-url]

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Getting Started

### Prerequisites

* macOS 13 (Ventura) or later
* Xcode 15+ with the macOS SDK and command-line tools
* [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for regenerating the Xcode project from `Sources/project.yml`)

  ```sh
  brew install xcodegen
  ```

* [`jq`](https://jqlang.github.io/jq/) (used by `Scripts/setup` to merge hooks into agent settings)

  ```sh
  brew install jq
  ```

* Optional: [`xcbeautify`](https://github.com/cpisciotta/xcbeautify) for nicer build output

  ```sh
  brew install xcbeautify
  ```

### Installation

1. Clone the repo

   ```sh
   git clone https://github.com/sleimanzublidi/Vivarium.git
   cd Vivarium
   ```

2. Generate the Xcode project

   ```sh
   make regen
   ```

3. Build the app

   ```sh
   ./Scripts/build.sh --release # Release build of Vivarium.app
   ./Scripts/build.sh --open    # …and launch it
   ```

   The `.app` lands at `.build/Build/Products/Release/Vivarium.app`.
4. Install agent hooks

   ```sh
   ./Scripts/setup.sh --claude          # Claude Code (user-global)
   ./Scripts/setup.sh --copilot         # Copilot CLI  (user-global)
   ./Scripts/setup.sh --copilot-repo .  # Copilot CLI  (per-repo opt-in)
   ./Scripts/setup.sh --both            # both user-global
   ```

   The script copies a small `notify` helper to `~/.vivarium/notify` and idempotently merges hook entries into the chosen agent settings files. Existing entries owned by other tools are preserved; previous Vivarium entries are stripped and re-added on every run. Backups of any modified settings files are written alongside as `*.vivarium.bak`.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Usage

1. Launch `Vivarium.app`. A small floating tank appears, plus a menu bar item showing hook installation status for Claude Code and Copilot CLI (with a `./Scripts/setup.sh --…` hint when something is missing), plus **Show / Hide Tank** and **Quit Vivarium**.
2. Open a terminal and run `claude` or `copilot` in any project. Within a moment, a pet enters the tank from the right and starts animating in response to the session.
3. Per-project assignments are remembered. The first session in a new project gets an unassigned pet from your library; that mapping is saved to `~/.vivarium/settings.json` and reused next time.
4. **Right-click a pet** to swap which pet that session uses. **Left-click an idle pet** for a quick greeting.
5. **Drop a `.zip`** OpenPets pack onto the tank to install it. The pack is validated, copied into `~/.vivarium/pets/<id>`, and registered live — no restart.

Set `VIVARIUM_DEBUG_GRID=1` before launching to replace the tank with a 3×3 grid of all 9 pet states for visual validation of a pack.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Roadmap

* [ ] Rich menu bar: Always-on-Top toggle, background picker, hook installer GUI, default-pet picker, project-mappings editor, active-sessions debug list, preferences pane
* [ ] Glob-based project override editor (`~/.vivarium/projects.json`)
* [ ] Filesystem watching for packs added/modified outside the app
* [x] Persistent `SessionStore` snapshots across restarts
* [ ] Rotating logs (`notify.log`, `events.log`, `pets.log`)
* [ ] Surface pack validation issues in the menu ("Pets → Issues (N)")
* [ ] Show a balloon that looks like a terminal when running bash/shell tools.
* [ ] Detect rubber duck tools and show a thinking balloon with a duck on it.
* [ ] Click-through-on-hover for the tank

See the [open issues](https://github.com/sleimanzublidi/Vivarium/issues) for a full list of proposed features (and known issues).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.

If you have a suggestion that would make this better, please fork the repo and create a pull request. You can also simply open an issue with the tag "enhancement".

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

<p align="right">(<a href="#readme-top">back to top</a>)</p>

### Top contributors

<a href="https://github.com/sleimanzublidi/Vivarium/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=sleimanzublidi/Vivarium" alt="contrib.rocks image" />
</a>

## License

Distributed under the MIT License. See `LICENSE` for more information.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- ACKNOWLEDGMENTS -->
## Acknowledgments

* [OpenPets](https://github.com/alvinunreal/openpets) — the pet pack format and Codex spritesheet contract Vivarium consumes unchanged.
* [Clawd Tank](https://github.com/marciogranzotto/clawd-tank) — the original hardware companion that inspired this software port.
* [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) — the event surface that drives Claude Code pets.
* [GitHub Copilot CLI hooks](https://docs.github.com/en/copilot/reference/hooks-configuration) — the equivalent surface for Copilot pets.
* [Best-README-Template](https://github.com/othneildrew/Best-README-Template) — README scaffolding.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- MARKDOWN LINKS & IMAGES -->
[contributors-shield]: https://img.shields.io/github/contributors/sleimanzublidi/Vivarium.svg?style=for-the-badge
[contributors-url]: https://github.com/sleimanzublidi/Vivarium/graphs/contributors
[forks-shield]: https://img.shields.io/github/forks/sleimanzublidi/Vivarium.svg?style=for-the-badge
[forks-url]: https://github.com/sleimanzublidi/Vivarium/network/members
[stars-shield]: https://img.shields.io/github/stars/sleimanzublidi/Vivarium.svg?style=for-the-badge
[stars-url]: https://github.com/sleimanzublidi/Vivarium/stargazers
[issues-shield]: https://img.shields.io/github/issues/sleimanzublidi/Vivarium.svg?style=for-the-badge
[issues-url]: https://github.com/sleimanzublidi/Vivarium/issues
[license-shield]: https://img.shields.io/github/license/sleimanzublidi/Vivarium.svg?style=for-the-badge
[license-url]: https://github.com/sleimanzublidi/Vivarium/blob/main/LICENSE

[Swift-shield]: https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white
[Swift-url]: https://www.swift.org
[macOS-shield]: https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white
[macOS-url]: https://www.apple.com/macos/
[SpriteKit-shield]: https://img.shields.io/badge/SpriteKit-2396F3?style=for-the-badge&logo=apple&logoColor=white
[SpriteKit-url]: https://developer.apple.com/spritekit/
[Xcode-shield]: https://img.shields.io/badge/Xcode-1575F9?style=for-the-badge&logo=xcode&logoColor=white
[Xcode-url]: https://developer.apple.com/xcode/
[XcodeGen-shield]: https://img.shields.io/badge/XcodeGen-2D2D2D?style=for-the-badge
[XcodeGen-url]: https://github.com/yonaskolb/XcodeGen
