# Audiobookshelf

Audiobookshelf is a download manager for audiobooks stored on an
[Audiobookshelf](https://audiobookshelf.org) server. It copies audiobook files to the Compás audiobook
library so they can be used offline.

## What it does

- Connects to an Audiobookshelf server over HTTPS.
- Supports login with username/password or an API key.
- Browses audiobook libraries and books.
- Downloads all audio files belonging to a book, plus its cover when available.
- Shows actual download progress across the book's files.
- Recognizes series metadata and uses the series-aware audiobook layout.
- Lists downloaded books and deletes their local copies.

The delete action only removes the copy on the Compás device. It does not
delete anything from the Audiobookshelf server.

## What it does not do

This is intentionally a download-only plugin. It does not launch a player,
sync playback positions, or update Audiobookshelf listening progress.

## Installation

From the repository root, pass the Compás SD-card root to the installer:

```sh
./install_audiobookshelf.sh /path/to/compas-sd-card
```

The installer places the plugin in `.plugins/` and its icons in
`.plugin-assets/Audiobookshelf/`. Refresh plugins in Compás or restart the
player afterward.

## First-time setup

1. Open the **Audiobookshelf** tile under **Stream Media**.
2. Open **Settings → Server URL** and enter the server base URL, for example
   `https://audiobooks.example.com`.
3. Choose either **Login with username/password** or **API key (advanced)**.
4. Use **Test connection** to verify the configuration.
5. Choose **Libraries**, select an audiobook, and choose **Download**.

The URL should be the server base URL, without a trailing `/api`. The plugin
adds the API path itself.

## Files and folders

Downloads are stored under the Compás SD-card's `Audiobooks/` directory:

```text
Audiobooks/Author/Book/
Audiobooks/Author/Series/Book/
```

Books with series metadata use the second layout. Books without series
metadata use the first. Existing local files are managed through **Downloaded**
and can be removed with **Delete local copy**.

## Authentication and troubleshooting

- Prefer an API key if the server is configured for token-based access.
- If the connection test fails, verify the URL, TLS certificate, network
  connectivity, and server credentials.
- The plugin requires the Compás build to support asynchronous HTTP,
  downloads, and download-progress reporting.
- If a book's series is not detected, check that series metadata is present on
  the Audiobookshelf item and refresh its metadata in the plugin.
