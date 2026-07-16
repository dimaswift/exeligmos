import type { Route } from "./+types/reference-inspector";
import { isEntityId, isReferenceKind } from "~/features/references/model";
import { FeaturePlaceholder } from "~/features/placeholders/feature-placeholder";

export default function ReferenceInspector({ params }: Route.ComponentProps) {
  if (!isReferenceKind(params.entityType) || !isEntityId(params.entityId)) {
    throw new Response("Unsupported reference type.", { status: 404 });
  }
  return (
    <FeaturePlaceholder
      contract="The typed reference contract is the persistence boundary. Phase 1 reserves this inspector surface; feature loaders and graph navigation follow later."
      eyebrow={`${params.entityType} reference`}
      summary={`Inspector target: ${params.entityId}`}
      title="Reference inspector"
    />
  );
}
