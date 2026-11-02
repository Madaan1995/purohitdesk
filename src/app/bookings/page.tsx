import { AppHeader } from '@/app/_components/AppHeader';
import { dateLabel, timeRange } from '@/app/_components/BookingWhen';
import { BadCursorError, listBookings, type BookingSummary } from '@/app/_lib/bookings';
import { requirePractice } from '@/app/_lib/page-auth';
import { withTenantTx } from '@/db';
import { addDays, todayInZone } from '@/domain/time';
import { getLocale, getTranslations } from 'next-intl/server';
import Link from 'next/link';

export default async function BookingsPage({
  searchParams,
}: {
  searchParams: Promise<{ view?: string | string[]; cursor?: string | string[] }>;
}) {
  const { actorId, current } = await requirePractice();
  const sp = await searchParams;
  const past = sp.view === 'past';
  const cursor = typeof sp.cursor === 'string' ? sp.cursor : undefined;
  const tz = current.organization.timezone;
  const today = todayInZone(tz);
  const range = past ? { from: addDays(today, -30), to: addDays(today, -1) } : { from: today, to: addDays(today, 365) };
  const page = await withTenantTx({ actorId, tenantId: current.organization.id }, async (tx) => {
    try {
      return await listBookings(tx, { ...range, limit: 50, cursor });
    } catch (error) {
      if (error instanceof BadCursorError) return listBookings(tx, { ...range, limit: 50 });
      throw error;
    }
  });
  const t = await getTranslations('bookings');
  const ts = await getTranslations('bookingStatus');
  const locale = await getLocale();
  const canCreate = current.permissions.includes('BOOKING_CREATE');
  const days = new Map<string, BookingSummary[]>();
  for (const b of page.data) days.set(b.local_date, [...(days.get(b.local_date) ?? []), b]);
  const more = page.next_cursor
    ? `/bookings?${new URLSearchParams({ ...(past ? { view: 'past' } : {}), cursor: page.next_cursor })}`
    : null;
  const tab = (active: boolean) =>
    `flex min-h-11 flex-1 items-center justify-center rounded-lg text-base ${active ? 'bg-brand font-semibold text-white' : 'border border-neutral-300'}`;

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-4 px-4 py-6">
        <h1 className="text-2xl font-bold">{t('title')}</h1>
        <nav className="flex gap-2">
          <Link href="/bookings" className={tab(!past)} aria-current={!past ? 'page' : undefined}>
            {t('upcoming')}
          </Link>
          <Link href="/bookings?view=past" className={tab(past)} aria-current={past ? 'page' : undefined}>
            {t('past')}
          </Link>
        </nav>
        {canCreate && (
          <Link
            href="/bookings/new"
            className="flex min-h-11 items-center justify-center rounded-lg bg-brand px-4 text-lg font-semibold text-white"
          >
            {t('new')}
          </Link>
        )}
        {page.data.length === 0 && <p className="text-base text-neutral-600">{t('none')}</p>}
        {[...days].map(([day, list]) => (
          <section key={day} className="flex flex-col gap-2">
            <h2 className="text-lg font-semibold">{dateLabel(day, locale)}</h2>
            <ul className="flex flex-col gap-2">
              {list.map((b) => (
                <li key={b.id}>
                  <Link href={`/bookings/${b.id}`} className="flex min-h-11 flex-col rounded-lg border border-neutral-200 px-3 py-2">
                    <span className="flex justify-between gap-2 text-base">
                      <span className="font-semibold">{timeRange(b, { notFixed: t('timeNotFixed') })}</span>
                      <span className="text-neutral-600">{ts(b.status)}</span>
                    </span>
                    <span className="text-base">
                      {locale === 'hi' ? b.offering.name_hi : b.offering.name_en} — {b.customer.display_name}
                    </span>
                    <span className="text-base text-neutral-500">{b.booking_number}</span>
                  </Link>
                </li>
              ))}
            </ul>
          </section>
        ))}
        {more && (
          <Link href={more} className="flex min-h-11 items-center justify-center rounded-lg border border-neutral-300 text-base">
            {(await getTranslations('customers'))('loadMore')}
          </Link>
        )}
      </main>
    </>
  );
}
