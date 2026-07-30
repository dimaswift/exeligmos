import assert from "node:assert/strict";
import test from "node:test";

import { verticalSymmetryFilter } from "../src/image-generation.mjs";

test("vertical symmetry preserves the left and reflects it into the right", () => {
  assert.equal(
    verticalSymmetryFilter(),
    [
      "[0:v]crop=iw/2:ih:0:0,split=2[original][reflection]",
      "[reflection]hflip[mirrored]",
      "[original][mirrored]hstack=inputs=2[symmetry]",
    ].join(";"),
  );
});
