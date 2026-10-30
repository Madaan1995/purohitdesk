import { SiteFooter } from "./_components/SiteFooter";

export default function Home() {
  return (
    <div className="flex min-h-dvh flex-col">
      <main className="flex flex-1 flex-col items-center justify-center gap-2 px-4 text-center">
        <h1 className="text-3xl font-bold text-brand">पुरोहित डेस्क</h1>
        <p lang="en" className="text-xl text-neutral-700">
          PurohitDesk
        </p>
      </main>
      <SiteFooter />
    </div>
  );
}
