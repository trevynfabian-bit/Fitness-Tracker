import * as React from "react";

import { cn } from "@/lib/utils";

export function Alert({
  tone = "error",
  className,
  children,
}: {
  tone?: "error" | "info";
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div
      role={tone === "error" ? "alert" : "status"}
      className={cn(
        "rounded-md border px-3 py-2 text-sm",
        tone === "error"
          ? "border-destructive/40 bg-destructive/10 text-destructive"
          : "border-border bg-muted text-muted-foreground",
        className,
      )}
    >
      {children}
    </div>
  );
}
