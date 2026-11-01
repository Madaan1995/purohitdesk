import Link from "next/link";

// Public links; /privacy and /terms need no sign-in.
export function SiteFooter() {
  return (
    <footer className="flex flex-wrap items-center justify-center gap-x-4 border-t border-neutral-200 px-4 py-2 text-base">
      <Link href="/privacy" className="flex min-h-11 items-center text-neutral-700 underline">
        गोपनीयता · <span lang="en">Privacy</span>
      </Link>
      <Link href="/terms" className="flex min-h-11 items-center text-neutral-700 underline">
        नियम व शर्तें · <span lang="en">Terms</span>
      </Link>
    </footer>
  );
}
