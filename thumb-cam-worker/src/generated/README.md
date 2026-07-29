# Generated temporal runtime

`temporal-core.mjs` is a dependency-free bundle of the canonical
`@fractonica/temporal-core` record-context calculation. Regenerate it from the
repository root with:

```sh
npm --prefix thumb-cam-worker run temporal:generate
```

The worker reads the canonical solar eclipse dataset directly from the web
source tree, so the generated runtime contains logic only.
