# Dreamer worker

Dreamer schedules the next native Tera (`000000`) rollover for each of the 40
active Saros series. At a rollover it chooses the oldest eligible public record
that carries that Saros spike and has no Dreamer tag, describes each image,
summarizes the source as a dream, creates an MLX Studio image, corrects its
orientation, and applies bilateral symmetry across a vertical axis. It then
publishes a new record linked to the source by its five-character ID.
The new date is the first whole 12d 20h 41m rollover after the current time.
Every dream begins with an LLM-authored signature of 3–12 emojis; spaces may
separate the emojis into meaningful groups.

Dream attempts are counted durably by the server per source record. Dreamer
retries a failed source twice, then marks it with the `Dreamer` tag and skips it
after the third failure so one unavailable or malformed record cannot block the
schedule. A restart during an attempt does not reset this counter.

Recent info, warning, and error events are stored by the server and shown on
both `/dreamer` and `/workers`. The local LaunchAgent also keeps plain logs in
`~/Library/Logs/Fractonica/dreamer-worker.log` and
`~/Library/Logs/Fractonica/dreamer-worker.error.log`.

An authenticated owner can also open any public record and press **Dream**.
That creates a durable on-demand job for the exact source record. Dreamer checks
this queue every five seconds, processes on-demand dreams ahead of the next
scheduled rollover, and exposes progress through the existing Jobs page.

Configure and install the macOS background service:

```sh
npm run configure
```

The process remains loaded at login. Use the Fractonica **Dreamer** page to
start or stop it, edit its image-prompt reference, inspect the 40 upcoming
rollovers, follow the live countdown, and browse every generated dream.
