// This entry is bundled into a dependency-free runtime module for the worker.
// The implementation itself remains owned by the canonical web temporal core.
export {
  journalEventContext,
  upcomingSarosRollovers,
} from "../../web/packages/temporal-core/src/saros.js";
