import { AppHeader } from '@/app/_components/AppHeader';
import { BlockForm } from '@/app/_components/BlockForm';
import { dateLabel } from '@/app/_components/BookingWhen';
import { ReleaseBlockButton } from '@/app/_components/ReleaseBlockButton';
import { loadAgenda } from '@/app/_lib/agenda';
import { ownPriestProfile } from '@/app/_lib/booking-page';
import { requirePractice } from '@/app/_lib/page-auth';
import { withTenantTx } from '@/db';
import { localRangeBounds, spansByDay, weekDays } from '@/domain/agenda';
import { addDays, isValidLocalDate, localTimeInZone, todayInZone } from '@/domain/time';
import { getLocale, getTranslations } from 'next-intl/server';
import Link from 'next/link';

type Item =
  | { type: 'booking'; key: string; starts_at: string; ends_at: string; id: string; label: string; sub: string; tentative: boolean }
  | { type: 'block'; key: string; starts_at: string; ends_at: string; id: string; note: string | null; priest: string; canRelease: boolean }
  | { type: 'busy'; key: string; starts_at: string; ends_at: string; priest: string };

export default async function AgendaPage({ searchParams }: { searchParams: Promise<{ view?: string; date?: string }> }) {
  const { actorId, current } = await requirePractice();
  const sp = await searchParams;
  const tz = current.organization.timezone;
  const today = todayInZone(tz);
  const date = typeof sp.date === 'string' && isValidLocalDate(sp.date) ? sp.date : today;
  const week = sp.view === 'week';
  const days = week ? weekDays(date) : [date];
  const { from, to } = localRangeBounds(days[0], days[days.length - 1], tz);

  const data = await withTenantTx({ actorId, tenantId: current.organization.id }, async (tx) => ({
    ...(await loadAgenda(tx, from, to, today)),
    profile: await ownPriestProfile(tx),
  }));
  const t = await getTranslations('agenda');
  const tb = await getTranslations('bookings');
  const ts = await getTranslations('bookingStatus');
  const locale = await getLocale();
  const has = (p: string) => current.permissions.includes(p as never);
  const manageAll = has('BLOCK_MANAGE');
  // BLOCK_MANAGE_OWN covers the actor's own calendar only; the database re-checks every write.
  const ownLinks = new Set(
    has('BLOCK_MANAGE_OWN') ? data.priests.filter((p) => p.priest_profile_id === data.profile).map((p) => p.id) : [],
  );
  const multiPriest = data.priests.length > 1;

  const items: Item[] = [
    ...data.bookings.map((b) => ({
      type: 'booking' as const,
      key: `b-${b.id}`,
      starts_at: b.starts_at,
      ends_at: b.ends_at,
      id: b.id,
      label: `${locale === 'hi' ? b.offering_hi : b.offering_en} — ${b.customer_name}`,
      sub: `${b.booking_number} · ${ts(b.status)}`,
      tentative: b.is_time_tentative,
    })),
    ...data.blocks.map((k) => ({
      type: 'block' as const,
      key: `k-${k.id}`,
      starts_at: k.starts_at,
      ends_at: k.ends_at,
      id: k.id,
      note: k.note,
      priest: k.priest_name,
      canRelease: manageAll || ownLinks.has(k.organization_priest_id),
    })),
    ...data.busy.map((s, i) => ({ type: 'busy' as const, key: `s-${i}`, starts_at: s.starts_at, ends_at: s.ends_at, priest: s.priest_name })),
  ];
  const byDay = spansByDay(items, days, tz);
  const time = (i: Item) =>
    `${'tentative' in i && i.tentative ? '≈ ' : ''}${localTimeInZone(new Date(i.starts_at), tz)}–${localTimeInZone(new Date(i.ends_at), tz)}`;
  const nav = (d: string, v = week) => `/agenda?${new URLSearchParams({ ...(v ? { view: 'week' } : {}), date: d })}`;
  const step = week ? 7 : 1;
  const tab = (active: boolean) =>
    `flex min-h-11 flex-1 items-center justify-center rounded-lg text-base ${active ? 'bg-brand font-semibold text-white' : 'border border-neutral-300'}`;
  const blockPriests = (manageAll ? data.priests : data.priests.filter((p) => ownLinks.has(p.id))).map((p) => ({
    id: p.id,
    display_name: p.display_name,
  }));

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-4 px-4 py-6">
        <h1 className="text-2xl font-bold">{t('title')}</h1>
        <nav className="flex gap-2">
          <Link href={nav(date, false)} className={tab(!week)} aria-current={!week ? 'page' : undefined}>
            {t('day')}
          </Link>
          <Link href={nav(date, true)} className={tab(week)} aria-current={week ? 'page' : undefined}>
            {t('week')}
          </Link>
        </nav>
        <nav className="flex gap-2">
          <Link href={nav(addDays(date, -step))} className="flex min-h-11 flex-1 items-center justify-center rounded-lg border border-neutral-300 text-base">
            ← {t('prev')}
          </Link>
          <Link href={nav(today)} className="flex min-h-11 flex-1 items-center justify-center rounded-lg border border-neutral-300 text-base">
            {t('today')}
          </Link>
          <Link href={nav(addDays(date, step))} className="flex min-h-11 flex-1 items-center justify-center rounded-lg border border-neutral-300 text-base">
            {t('next')} →
          </Link>
        </nav>

        {data.toFix.length > 0 && (
          <section className="flex flex-col gap-2 rounded-lg bg-amber-50 p-3">
            <h2 className="text-lg font-semibold text-amber-900">{t('timeToFix')}</h2>
            <ul className="flex flex-col gap-2">
              {data.toFix.map((b) => (
                <li key={b.id}>
                  <Link href={`/bookings/${b.id}`} className="flex min-h-11 flex-col rounded-lg bg-white px-3 py-2">
                    <span className="text-base font-semibold">{dateLabel(b.local_date, locale)} · {tb('timeNotFixed')}</span>
                    <span className="text-base">
                      {locale === 'hi' ? b.offering_hi : b.offering_en} — {b.customer_name}
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          </section>
        )}

        {days.map((day) => {
          const list = byDay.get(day) ?? [];
          return (
            <section key={day} className="flex flex-col gap-2">
              <h2 className={`text-lg font-semibold ${day === today ? 'text-brand' : ''}`}>{dateLabel(day, locale)}</h2>
              {list.length === 0 ? (
                <p className="text-base text-neutral-600">{t('nothing')}</p>
              ) : (
                <ul className="flex flex-col gap-2">
                  {list.map((i) => (
                    <li key={`${day}-${i.key}`}>
                      {i.type === 'booking' && (
                        <Link href={`/bookings/${i.id}`} className="flex min-h-11 flex-col rounded-lg border border-neutral-200 px-3 py-2">
                          <span className="text-base font-semibold">{time(i)}</span>
                          <span className="text-base">{i.label}</span>
                          <span className="text-base text-neutral-500">{i.sub}</span>
                        </Link>
                      )}
                      {i.type === 'block' && (
                        <div className="flex items-center justify-between gap-2 rounded-lg border border-neutral-300 bg-neutral-100 px-3 py-2">
                          <span className="flex flex-col">
                            <span className="text-base font-semibold">{time(i)}</span>
                            <span className="text-base">
                              {t('blocked')}
                              {i.note ? `: ${i.note}` : ''}
                              {multiPriest ? ` · ${i.priest}` : ''}
                            </span>
                          </span>
                          {i.canRelease && <ReleaseBlockButton tenantId={current.organization.id} blockId={i.id} />}
                        </div>
                      )}
                      {i.type === 'busy' && (
                        <div className="flex flex-col rounded-lg border border-dashed border-neutral-400 px-3 py-2 text-neutral-700">
                          <span className="text-base font-semibold">{time(i)}</span>
                          <span className="text-base">
                            {t('busyOther')}
                            {multiPriest ? ` · ${i.priest}` : ''}
                          </span>
                        </div>
                      )}
                    </li>
                  ))}
                </ul>
              )}
            </section>
          );
        })}

        {blockPriests.length > 0 && (
          <BlockForm tenantId={current.organization.id} timeZone={tz} date={date} priests={blockPriests} />
        )}
      </main>
    </>
  );
}
