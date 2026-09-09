/**
 * Loading placeholder. Deliberately shapes only, never numbers: a skeleton
 * that shows plausible values is a fabricated measurement for as long as it is
 * on screen.
 */
export function PageSkeleton({ tiles = 4, blocks = 2 }: { tiles?: number; blocks?: number }) {
  return (
    <div className="mx-auto w-full max-w-5xl animate-pulse px-6 py-10" aria-busy="true">
      <div className="h-8 w-56 rounded-md bg-muted" />
      <div className="mt-2 h-4 w-72 rounded-md bg-muted" />
      <div className="mt-8 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {Array.from({ length: tiles }).map((_, index) => (
          <div key={index} className="h-24 rounded-lg border border-border bg-muted/40" />
        ))}
      </div>
      <div className="mt-6 grid gap-3 lg:grid-cols-2">
        {Array.from({ length: blocks }).map((_, index) => (
          <div key={index} className="h-64 rounded-lg border border-border bg-muted/40" />
        ))}
      </div>
      <span className="sr-only">Loading</span>
    </div>
  );
}
