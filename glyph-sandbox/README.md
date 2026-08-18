# Glyph Foundry

A standalone, client-only laboratory for bit-driven glyph systems. It deliberately does not import
or change Fractonica's canonical octal glyph package: experimental configurations remain separate
until a rule is intentionally promoted into the domain specification.

The default is a four-bit hexadecimal system. Bit widths from 2 through 16 are supported, including
base 8 at 3 bits, base 16 at 4 bits, base 32 at 5 bits, base 256 at 8 bits, and base 65,536 at 16
bits. Radices through 36 use single-character digits; larger radices use whitespace-separated decimal
values.

```sh
npm install
npm run dev
```

The app stores the current experiment in browser local storage. Configurations can also be exported
and imported as JSON, and the current composite can be downloaded as SVG. The print-template surface
turns the current bit geometry into an A4 or Letter sheet of repeated dot fields for hand drawing,
with blank-practice and guided-digit modes.

Line assembly includes adjustable glyph spacing. Ink, preview background, and the shared position or
digit palette are editable and saved with the experiment.
