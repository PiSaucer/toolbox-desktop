# toolbox desktop

toolbox desktop is a desktop link listener for [toolbox](https://github.com/PiSaucer/toolbox/tree/main). It registers the `toolbox://` URL scheme, so toolbox links can open and be processed by a native desktop application.

For example:

```text
toolbox://download/id
```

The application bundles `toolbox.py` and the other components needed to handle these links on the user's computer.

## Installation

Install toolbox desktop on macOS with [Homebrew](https://brew.sh/):

```bash
brew install --cask pisaucer/tap/toolbox-desktop
```

## toolbox links

* [Source code](https://github.com/PiSaucer/toolbox/tree/main)
* [toolbox website](https://pisaucer.github.io/toolbox/)
* [Python package](https://pypi.org/project/pisaucer-toolbox/)
