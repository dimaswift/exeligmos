# Exeligmos Sync Server

Run this on a Mac/PC on the same Wi-Fi network as the iPhone.

```sh
cd sync-server
npm start
```

Open the printed URL in a browser to browse the latest pushed backup. In the iOS app, go to Settings -> LAN Sync, enter the same URL, then use:

- Test server connection
- Push backup to server
- Sync new records now
- Auto sync new records
- Restore latest from server

Backups are stored under `sync-server/data/`. Override with:

```sh
EXELIGMOS_SYNC_DATA=/path/to/backups npm start
```

Troubleshooting:

- Open `http://<computer-ip>:8787/health` from the phone browser. It should show JSON with `ok: true`.
- Open `http://<computer-ip>:8787/api/manifest` to see which thread, record, and media IDs are already on the server.
- If the app says `HTTP 404` with `No backup has been pushed yet`, push from the app before restoring.
- If the browser downloads an empty file, make sure this Node server is running with `npm start`, not a generic static file server on the same port.
- If a push returns `HTTP 413`, start the server with a larger limit, for example `MAX_BODY_BYTES=4294967296 npm start`.
