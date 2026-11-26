# Desk Quote

Put your own text on the macOS desktop, right over the wallpaper, with no background.

![Desk Quote on the desktop](docs/screenshot.jpg)

Desk Quote is not a widget. macOS widgets always draw their own background, and the system controls how they look. Desk Quote draws only the text, in the font, size and color you choose.

## Features

- Fully transparent: only the text is drawn.
- Sits below all your windows, so you see it only on the bare desktop.
- Clicks pass through it.
- Shows on every Space.
- Any macOS font, size and color, including opacity.
- Top, center or bottom position.
- Optional soft shadow, so the text stays readable on light wallpapers.
- Can open at login.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`)

## Install

There are no prebuilt releases yet. Build from source:

```bash
git clone https://github.com/gnapse/desk-quote.git
cd desk-quote
./build.sh
```

The script builds `DeskQuote.app`, copies it to `~/Applications`, and opens it.

## Use

Click the quote icon in the menu bar:

- **Edit Text…**: type your text. The desktop updates as you type.
- **Font…** and **Color…**: change the look. Changes apply live.
- **Position**: top, center or bottom.
- **Text Shadow**: turn the shadow on or off.
- **Open at Login**: start Desk Quote when you log in.

## How it works

Desk Quote is a borderless window with a clear background. It sits at the window level just above the desktop icons, below every normal window. It ignores mouse events and joins all Spaces. The menu bar item is the only way to control it, and the app has no Dock icon.

The whole app is one Swift file: [`Sources/main.swift`](Sources/main.swift).

## Limits

- It shows on the main display only.
- It shows one text at a time.

## License

[MIT](LICENSE)
