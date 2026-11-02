import { AppHeader } from '@/app/_components/AppHeader';
import { BookingActions } from '@/app/_components/BookingActions';
import { dateLabel, timeRange } from '@/app/_components/BookingWhen';
import { ownPriestProfile } from '@/app/_lib/booking-page';
import { getBooking, UUID } from '@/app/_lib/bookings';
import { requirePractice } from '@/app/_lib/page-auth';
import { withTenantTx } from '@/db';
import { formatPaise } from '@/domain/money';
import type { Permission } from '@/domain/permissions';
import { getLocale, getTranslations } from 'next-intl/server';
import Link from 'next/link';
import { notFound } from 'next/navigation';

export default async function BookingPage({ params }: { params: Promise<{ bookingId: string }> }) {
  const { bookingId } = await params;
  const { actorId, current } = await requirePractice();
  if (!UUID.test(bookingId)) notFound();
  const data = await withTenantTx({ actorId, tenantId: current.organization.id }, async (tx) => ({
    booking: await getBooking(tx, bookingId),
    profile: await ownPriestProfile(tx),
  }));
  const b = data.booking;
  if (!b) notFound();
  const t = await getTranslations('bookings');
  const ts = await getTranslations('bookingStatus');
  const locale = await getLocale();
  const has = (p: Permission) => current.permissions.includes(p);
  const lead = b.priests.find((p) => p.role === 'LEAD');
  const leads = Boolean(lead && data.profile && lead.priest_profile_id === data.profile);
  const may = (p: 'CONFIRM' | 'CANCEL' | 'COMPLETE') =>
    has(`BOOKING_${p}` as Permission) || (has(`BOOKING_${p}_OWN` as Permission) && leads);
  const row = 'flex flex-col gap-1 border-b border-neutral-100 pb-2';

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-4 px-4 py-6">
        <Link href="/bookings" className="text-base text-brand underline">
          {t('back')}
        </Link>
        <div className="flex flex-col gap-1">
          <h1 className="text-2xl font-bold">{locale === 'hi' ? b.offering.name_hi : b.offering.name_en}</h1>
          <p className="text-base text-neutral-600">
            {b.booking_number} · <span className="font-semibold">{ts(b.status)}</span>
          </p>
        </div>
        <dl className="flex flex-col gap-2">
          <div className={row}>
            <dt className="text-base text-neutral-600">{t('when')}</dt>
            <dd className="text-lg font-semibold">
              {dateLabel(b.local_date, locale)}, {timeRange(b, { notFixed: t('timeNotFixed') })}
            </dd>
          </div>
          <div className={row}>
            <dt className="text-base text-neutral-600">{t('customer')}</dt>
            <dd className="text-base">
              <Link href={`/customers/${b.customer.id}`} className="text-brand underline">
                {b.customer.display_name}
              </Link>
            </dd>
          </div>
          {b.location && (
            <div className={row}>
              <dt className="text-base text-neutral-600">{t('place')}</dt>
              <dd className="whitespace-pre-line text-base">{b.location}</dd>
            </div>
          )}
          {b.priests.length > 0 && (
            <div className={row}>
              <dt className="text-base text-neutral-600">{t('priest')}</dt>
              <dd className="text-base">{b.priests.map((p) => p.display_name).join(', ')}</dd>
            </div>
          )}
          {b.agreed_dakshina_paise !== null && (
            <div className={row}>
              <dt className="text-base text-neutral-600">{t('dakshina')}</dt>
              <dd className="text-base">{formatPaise(b.agreed_dakshina_paise)}</dd>
            </div>
          )}
          {b.buffer_before_min !== null && b.buffer_after_min !== null && (
            <p className="text-base text-neutral-600">
              {t('buffers', { before: b.buffer_before_min, after: b.buffer_after_min })}
            </p>
          )}
          {b.buffer_overlap_ack && (
            <p className="rounded-lg bg-amber-50 px-3 py-2 text-base text-amber-900">{t('bufferAcknowledged')}</p>
          )}
          {b.title && <p className="text-base">{b.title}</p>}
          {b.notes && <p className="whitespace-pre-line text-base text-neutral-700">{b.notes}</p>}
          {b.cancel_reason && <p className="text-base text-neutral-700">{t('cancelledBecause', { reason: b.cancel_reason })}</p>}
        </dl>
        {has('BOOKING_EDIT') && (
          <Link
            href={`/bookings/${b.id}/edit`}
            className="flex min-h-11 items-center justify-center rounded-lg border border-brand px-4 text-lg text-brand"
          >
            {t('edit')}
          </Link>
        )}
        {b.status === 'CONFIRMED' && may('CONFIRM') && (
          <Link
            href={`/bookings/${b.id}/reschedule`}
            className="flex min-h-11 items-center justify-center rounded-lg border border-brand px-4 text-lg text-brand"
          >
            {t('reschedule')}
          </Link>
        )}
        <BookingActions
          tenantId={current.organization.id}
          timeZone={b.timezone}
          bookingId={b.id}
          version={b.version}
          status={b.status}
          span={b.starts_at && b.ends_at ? { starts_at: b.starts_at, ends_at: b.ends_at } : null}
          can={{ confirm: may('CONFIRM'), cancel: may('CANCEL'), complete: may('COMPLETE') }}
        />
      </main>
    </>
  );
}
