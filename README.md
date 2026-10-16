# Redlib (agandhi4 fork)

> An alternative private front-end to Reddit, with its origins in [Libreddit](https://github.com/libreddit/libreddit).

> [!NOTE]
> **This is a personal fork**, heavily customized for a single self-hosted instance. Major divergences from upstream: a single dense "utility broadsheet" layout (system fonts, `color-mix()` design tokens), 8 curated WCAG-tuned themes including a Hacker News-inspired default, HN-grade comment ergonomics (depth ramp, hover actions, collapse controls), a mobile tab bar, offline reading via service worker, server-side saved posts, a rendered-HTML cache, a stale-while-revalidate Reddit cache with idle prefetch of the posts you're likely to open next, concurrent upstream fetches, and an async OAuth bootstrap that can't wedge on a bad network. **See [`docs/fork.md`](docs/fork.md) for the full list**, and [`AGENTS.md`](AGENTS.md) for architecture and conventions. Upstream docs below remain accurate for configuration; deployment is the fork's own (see [Deployment](#deployment)).

![screenshot](https://i.ibb.co/18vrdxk/redlib-rust.png)

---

**10-second pitch:** Redlib is a private front-end like [Invidious](https://github.com/iv-org/invidious) but for Reddit. Browse the coldest takes of [r/unpopularopinion](https://farside.link/redlib/r/unpopularopinion) without being [tracked](#reddit).

- 🚀 Fast: written in Rust for blazing-fast speeds and memory safety
- ☁️ Light: minimal JavaScript (progressive enhancement only — collapse controls, prefetch, offline cache), no ads, no tracking, no bloat
- 🕵 Private: all requests are proxied through the server, including media
- 🔒 Secure: strong [Content Security Policy](https://developer.mozilla.org/en-US/docs/Web/HTTP/CSP) prevents browser requests to Reddit

---

## Table of Contents

1. [Redlib](#redlib)
2. [Instances](#instances)
3. [About](#about)
   - [Built with](#built-with)
   - [How is it different from other Reddit front ends?](#how-is-it-different-from-other-reddit-front-ends)
     - [Teddit](#teddit)
     - [Libreddit](#libreddit)
4. [Comparison](#comparison)
   - [Speed](#speed)
   - [Privacy](#privacy)
     - [Reddit](#reddit)
     - [Redlib](#redlib-1)
       - [Server](#server)
5. [Running this fork](#running-this-fork)
   - [Getting started](#getting-started)
   - [Commands](#commands)
   - [Architecture](#architecture)
   - [Deployment](#deployment)
   - [Tracking upstream](#tracking-upstream)
   - [Documentation](#documentation)
6. [Configuration](#configuration)
   - [Instance settings](#instance-settings)
   - [Default user settings](#default-user-settings)

---

# Instances

> [!TIP]
> 🔗 **Want to automatically redirect Reddit links to Redlib? Use [LibRedirect](https://github.com/libredirect/libredirect) or [Privacy Redirect](https://github.com/SimonBrazell/privacy-redirect)!**

An up-to-date table of instances is available in [Markdown](https://github.com/redlib-org/redlib-instances/blob/main/instances.md) and [machine-readable JSON](https://github.com/redlib-org/redlib-instances/blob/main/instances.json).

Both files are part of the [redlib-instances](https://github.com/redlib-org/redlib-instances) repository. To contribute your [self-hosted instance](#deployment) to the list, see the [redlib-instances README](https://github.com/redlib-org/redlib-instances/blob/main/README.md).

For information on instance uptime, see the [Uptime Robot status page](https://stats.uptimerobot.com/mpmqAs1G2Q).

---

# About

> [!NOTE]
> Find Redlib on 💬 [Matrix](https://matrix.to/#/#redlib:matrix.org), 🐋 [Quay.io](https://quay.io/repository/redlib/redlib), :octocat: [GitHub](https://github.com/redlib-org/redlib), and 🦊 [GitLab](https://gitlab.com/redlib/redlib).

Redlib hopes to provide an easier way to browse Reddit, without the ads, trackers, and bloat. Redlib was inspired by other alternative front-ends to popular services such as [Invidious](https://github.com/iv-org/invidious) for YouTube, [Nitter](https://github.com/zedeus/nitter) for Twitter, and [Bibliogram](https://sr.ht/~cadence/bibliogram/) for Instagram.

Redlib currently implements most of Reddit's (signed-out) functionalities but still lacks [a few features](https://github.com/redlib-org/redlib/issues).

## Built with

- [Rust](https://www.rust-lang.org/) - Programming language
- [Hyper](https://github.com/hyperium/hyper) - HTTP server and client
- [Askama](https://github.com/askama-rs/askama) - Templating engine
- [Rustls](https://github.com/rustls/rustls) - TLS library

## How is it different from other Reddit front ends?

### Teddit

Teddit is another awesome open source project designed to provide an alternative frontend to Reddit. There is no connection between the two, and you're welcome to use whichever one you favor. Competition fosters innovation and Teddit's release has motivated me to build Redlib into an even more polished product.

If you are looking to compare, the biggest differences I have noticed are:

- Redlib is themed around Reddit's redesign whereas Teddit appears to stick much closer to Reddit's old design. This may suit some users better as design is always subjective.
- Redlib is written in [Rust](https://www.rust-lang.org) for speed and memory safety. It uses [Hyper](https://hyper.rs), a speedy and lightweight HTTP server/client implementation.

### Libreddit

While originating as a fork of Libreddit, the name "Redlib" was adopted to avoid legal issues, as Reddit only allows the use of their name if structured as "XYZ For Reddit".

Several technical improvements have also been made, including:

- **OAuth token spoofing**: To circumvent rate limits imposed by Reddit, OAuth token spoofing is used to mimick the most common iOS and Android clients. While spoofing both iOS and Android clients was explored, only the Android client was chosen due to content restrictions when using an anonymous iOS client.
- **Token refreshing**: The authentication token is refreshed every 24 hours, emulating the behavior of the official Android app.
- **HTTP header mimicking**: Efforts are made to send along as many of the official app's headers as possible to reduce the likelihood of Reddit's crackdown on Redlib's requests.

---

# Comparison

This section outlines how Redlib compares to Reddit in terms of speed and privacy.

## Speed

Last tested on January 12, 2024.

Results from Google PageSpeed Insights ([Redlib Report](https://pagespeed.web.dev/report?url=https%3A%2F%2Fredlib.matthew.science%2F), [Reddit Report](https://pagespeed.web.dev/report?url=https://www.reddit.com)).

| Performance metric  | Redlib   | Reddit    |
|---------------------|----------|-----------|
| Speed Index         | 0.6s     | 1.9s      |
| Performance Score   | 100%     | 64%       |
| Time to Interactive | **2.8s** | **12.4s** |

## Privacy

### Reddit

**Logging:** According to Reddit's [privacy policy](https://www.redditinc.com/policies/privacy-policy), they "may [automatically] log information" including:

- IP address
- User-agent string
- Browser type
- Operating system
- Referral URLs
- Device information (e.g., device IDs)
- Device settings
- Pages visited
- Links clicked
- The requested URL
- Search terms

**Location:** The same privacy policy goes on to describe that location data may be collected through the use of:

- GPS (consensual)
- Bluetooth (consensual)
- Content associated with a location (consensual)
- Your IP Address

**Cookies:** Reddit's [cookie notice](https://www.redditinc.com/policies/cookies) documents the array of cookies used by Reddit including/regarding:

- Authentication
- Functionality
- Analytics and Performance
- Advertising
- Third-Party Cookies
- Third-Party Site

### Redlib

For transparency, I hope to describe all the ways Redlib handles user privacy.

#### Server

- **Logging:** In production (when running the binary, hosting with docker, or using the official instances), Redlib logs nothing. When debugging (running from source without `--release`), Redlib logs post IDs fetched to aid with troubleshooting.

- **Cookies:** Redlib uses optional cookies to store any configured settings in the settings menu. These are not cross-site cookies and the cookies hold no personal data.

---

# Running this fork

This block is the fork's own; everything outside it is upstream's text, kept for configuration reference.

## Getting started

```bash
make install            # once per checkout or worktree: git hooks (core.hooksPath=.githooks)
cp .env.example .env    # read from the working directory at startup; edit as needed
REDLIB_DB_PATH=/tmp/redlib.db cargo run -- -p 8199
```

The listener opens only after the OAuth bootstrap against Reddit succeeds, so a local run needs network access to Reddit. The Mac has no system Rust; prefix commands with `PATH="$(devkit/bin/rust_toolchain.sh .):$PATH"` to use the pinned toolchain from `rust-toolchain.toml`.

## Commands

| Command | Does |
|---|---|
| `make ci-quick` | devkit, toolchain, workflow, docs and release guards, `cargo fmt --check`, clippy `-D warnings` |
| `make ci-unit` | `cargo test`, offline, under a time budget and a test-count floor |
| `make ci-image` | builds the Dockerfile for this host's platform and checks its `APP_VERSION` |
| `make test-live` | the `#[ignore]`d tests that call live Reddit, serially; gates nothing |
| `make gate PR=<n>` | the merge gate: the PR merged into `origin/main`, posting the `local-gate` status |
| `make help` | every target |

## Architecture

One Rust binary (hyper server, `src/main.rs` router) that proxies Reddit's JSON API and media, renders HTML with askama templates, and serves every static asset compiled into the binary. In-memory caches sit in front of Reddit (a stale-while-revalidate JSON cache, a rendered-post cache), saved posts live in SQLite, and an OAuth bootstrap must succeed before the listener opens. The full map, with the rules that keep it working, is [`AGENTS.md`](AGENTS.md#architecture).

## Deployment

This fork runs one instance (`reddit.box`), so it carries one deployment path; upstream's recipes (Docker Compose and CLI, Podman Quadlets, systemd, launchd, Replit/Heroku, NetBSD) were removed with the files they used. See [upstream's README](https://github.com/redlib-org/redlib#deployment) for those.

- **Image:** every push to `main` builds `ghcr.io/agandhi4/redlib` (`.github/workflows/ghcr.yml`), tagged `sha-<7>` and `latest`, and creates the git tag `ship-<YYYY-MM-DD>-<sha7>`. The bare `<sha7>` is the image's `APP_VERSION`, its OCI version label and the version in the page footer.
- **Stack:** the compose file lives in the homelab repo (`stacks/redlib/docker-compose.yml`); its hourly `deploy.sh update` timer pulls `latest`. Instance settings are env vars there.

## Tracking upstream

This is a hard fork of [redlib-org/redlib](https://github.com/redlib-org/redlib) (fork point, sync cadence and policy in [`docs/fork.md`](docs/fork.md)). Add the remote once per clone:

```bash
git remote add upstream https://github.com/redlib-org/redlib.git
git fetch upstream && git log --oneline main..upstream/main
```

## Documentation

- [`docs/fork.md`](docs/fork.md): what the fork changes and why, the fork point and the upstream sync policy.
- [`AGENTS.md`](AGENTS.md): architecture, conventions, CI and the PR gate, for humans and agent sessions alike.
- [`docs/decisions.md`](docs/decisions.md): dated decisions, newest last.
- [`devkit/README.md`](devkit/README.md): the vendored fleet tooling behind the `make` checks, hooks and gate.
- [`.env.example`](.env.example): every instance setting with its default.

---

# Configuration

You can configure Redlib further using environment variables. For example:

```bash
REDLIB_DEFAULT_SHOW_NSFW=on redlib
```

```bash
REDLIB_DEFAULT_WIDE=on REDLIB_DEFAULT_THEME=dark redlib -r
```

You can also configure Redlib with a configuration file named `redlib.toml`. For example:

```toml
REDLIB_DEFAULT_WIDE = "on"
REDLIB_DEFAULT_USE_HLS = "on"
```

> [!NOTE]
> The binary loads a `.env` file from its working directory at startup, so for a local run copy `.env.example` (every setting this fork reads, with its default) to `.env` and edit it. The instance's settings are env vars in the homelab compose file.
- Contributors and agents: see [AGENTS.md](AGENTS.md).

## Command Line Flags

Redlib supports the following command line flags:

- `-4`, `--ipv4-only`: Listen on IPv4 only.
- `-6`, `--ipv6-only`: Listen on IPv6 only.
- `-r`, `--redirect-https`: Redirect all HTTP requests to HTTPS (no longer functional).
- `-a`, `--address <ADDRESS>`: Sets address to listen on. Default is `[::]`.
- `-p`, `--port <PORT>`: Port to listen on. Default is `8080`.
- `-H`, `--hsts <EXPIRE_TIME>`: HSTS header to tell browsers that this site should only be accessed over HTTPS. Default is `604800`.

## Instance settings

Assign a default value for each instance-specific setting by passing environment variables to Redlib in the format `REDLIB_{X}`. Replace `{X}` with the setting name (see list below) in capital letters.

| Name                      | Possible values | Default value          | Description                                                                                               |
|---------------------------|-----------------|------------------------|-----------------------------------------------------------------------------------------------------------|
| `SFW_ONLY`                | `["on", "off"]` | `off`                  | Enables SFW-only mode for the instance, i.e. all NSFW content is filtered.                                |
| `BANNER`                  | String          | (empty)                | Allows the server to set a banner to be displayed. Currently this is displayed on the instance info page. |
| `ROBOTS_DISABLE_INDEXING` | `["on", "off"]` | `off`                  | Disables indexing of the instance by search engines.                                                      |
| `PUSHSHIFT_FRONTEND`      | String          | `undelete.pullpush.io` | Allows the server to set the Pushshift frontend to be used with "removed" links.                          |
| `PORT`                    | Integer 0-65535 | `8080`                 | The **internal** port Redlib listens on.                                                                  |
| `ENABLE_RSS`              | `["on", "off"]` | `off`                  | Enables RSS feed generation.                                                                              |
| `FULL_URL`                | String          | (empty)                | Allows for proper URLs (for now, only needed by RSS)                                                      |

## Default user settings

Assign a default value for each user-modifiable setting by passing environment variables to Redlib in the format `REDLIB_DEFAULT_{Y}`. Replace `{Y}` with the setting name (see list below) in capital letters.

| Name                                | Possible values                                                                                                                                                                                                                 | Default value |
|-------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------|
| `THEME`                             | `["system", "light", "dark", "black", "dracula", "nord", "laserwave", "violet", "gold", "rosebox", "gruvboxdark", "gruvboxlight", "tokyoNight", "icebergDark", "doomone", "libredditBlack", "libredditDark", "libredditLight"]` | `system`      |
| `FRONT_PAGE`                        | `["default", "popular", "all"]`                                                                                                                                                                                                 | `default`     |
| `LAYOUT`                            | `["card", "clean", "compact"]`                                                                                                                                                                                                  | `card`        |
| `WIDE`                              | `["on", "off"]`                                                                                                                                                                                                                 | `off`         |
| `POST_SORT`                         | `["hot", "new", "top", "rising", "controversial"]`                                                                                                                                                                              | `hot`         |
| `COMMENT_SORT`                      | `["confidence", "top", "new", "controversial", "old"]`                                                                                                                                                                          | `confidence`  |
| `BLUR_SPOILER`                      | `["on", "off"]`                                                                                                                                                                                                                 | `off`         |
| `SHOW_NSFW`                         | `["on", "off"]`                                                                                                                                                                                                                 | `off`         |
| `BLUR_NSFW`                         | `["on", "off"]`                                                                                                                                                                                                                 | `off`         |
| `USE_HLS`                           | `["on", "off"]`                                                                                                                                                                                                                 | `off`         |
| `HIDE_HLS_NOTIFICATION`             | `["on", "off"]`                                                                                                                                                                                                                 | `off`         |
| `AUTOPLAY_VIDEOS`                   | `["on", "off"]`                                                                                                                                                                                                                 | `off`         |
| `SUBSCRIPTIONS`                     | `+`-delimited list of subreddits (`sub1+sub2+sub3+...`)                                                                                                                                                                         | _(none)_      |
| `HIDE_AWARDS`                       | `["on", "off"]`                                                                                                                                                                                                                 | `off`         |
| `DISABLE_VISIT_REDDIT_CONFIRMATION` | `["on", "off"]`                                                                                                                                                                                                                 | `off`         |
| `HIDE_SCORE`                        | `["on", "off"]`                                                                                                                                                                                                                 | `off`         |
| `HIDE_SIDEBAR_AND_SUMMARY`          | `["on", "off"]`                                                                                                                                                                                                                 | `off`         |
| `FIXED_NAVBAR`                      | `["on", "off"]`                                                                                                                                                                                                                 | `on`          |
| `REMOVE_DEFAULT_FEEDS`              | `["on", "off"]`                                                                                                                                                                                                                 | `off`         |

## Forward Proxies

Redlib [supports](https://docs.rs/wreq/latest/wreq/#proxies) proxy usage using the standard `HTTP_PROXY` and
`HTTPS_PROXY` environment variables. Use `ALL_PROXY` to set both at the same time (which you want to do).

- `http://` is the scheme for http proxy
- `https://` is the scheme for https proxy
- `socks4://` is the scheme for socks4 proxy
- `socks4a://` is the scheme for socks4a proxy
- `socks5://` is the scheme for socks5 proxy
- `socks5h://` is the scheme for socks5h proxy

## Security

This project uses [BoringSSL](https://boringssl.googlesource.com/boringssl/), built from source with patches from
the [wreq](https://github.com/0x676e67/wreq) project. Certificates are validated against the embedded trust store from Mozilla.

## Building

Since Redlib uses [`boring-sys2`](https://crates.io/crates/boring-sys2), to build Redlib you will need to build
BoringSSL from source.

### Linux/MacOS

Refer to the [boringssl](https://github.com/google/boringssl/blob/main/BUILDING.md) documentation for dependencies.

### Windows

Install MSVC, which you likely already have for Rust.

```pwsh
# Make sure to update your PATH, some of the installers don't do that by default (hense -i, interactive mode).
winget install -i Kitware.CMake
winget install -i NASM.NASM
winget install -i LLVM.LLVM

# For tests.
winget install GoLang.Go
```
