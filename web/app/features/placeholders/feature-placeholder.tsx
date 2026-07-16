import styles from "./feature-placeholder.module.css";

export interface FeaturePlaceholderProps {
  readonly eyebrow: string;
  readonly title: string;
  readonly summary: string;
  readonly contract?: string;
}

export function FeaturePlaceholder({ eyebrow, title, summary, contract }: FeaturePlaceholderProps) {
  return (
    <section className={styles.panel}>
      <p className="eyebrow">{eyebrow}</p>
      <h1>{title}</h1>
      <p className={styles.summary}>{summary}</p>
      {contract === undefined ? null : (
        <div className={styles.contract}>
          <strong>Contract boundary</strong>
          <p>{contract}</p>
        </div>
      )}
    </section>
  );
}
