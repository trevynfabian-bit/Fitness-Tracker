import Link from "next/link";

import { Card } from "@/components/ui/card";
import { buttonVariants } from "@/components/ui/button";

/**
 * The no-data state.
 *
 * It shows no chart, no zero-filled series and no placeholder totals. A
 * zero-filled analytics panel for a user who has imported nothing is a
 * fabricated measurement, and this product does not fabricate measurements.
 * What it offers instead is the one action that changes the situation.
 */
export function TrainingEmptyState({
  title = "No training data yet",
  description = "Nothing has been imported into your account. Once an export is imported, your workouts, exercises and volume history appear here, built from the imported records themselves.",
  showAction = true,
}: {
  title?: string;
  description?: string;
  showAction?: boolean;
}) {
  return (
    <Card className="border-dashed py-10 text-center">
      <h2 className="text-base font-semibold">{title}</h2>
      <p className="mx-auto mt-2 max-w-md text-sm text-muted-foreground">{description}</p>
      {showAction ? (
        <div className="mt-6">
          <Link href="/import" className={buttonVariants({ size: "sm" })}>
            Import training data
          </Link>
        </div>
      ) : null}
    </Card>
  );
}
