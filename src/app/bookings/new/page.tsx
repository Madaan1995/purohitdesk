import { AppHeader } from '@/app/_components/AppHeader';
import { BookingForm } from '@/app/_components/BookingForm';
import { bookingFormData } from '@/app/_lib/booking-page';
import { UUID } from '@/app/_lib/bookings';
import { getCustomer } from '@/app/_lib/customers';
import { requirePractice } from '@/app/_lib/page-auth';
import { withTenantTx } from '@/db';
import { todayInZone } from '@/domain/time';
import { getTranslations } from 'next-intl/server';
import Link from 'next/link';
import { redirect } from 'next/navigation';

export default async function NewBookingPage({ searchParams }: { searchParams: Promise<{ customer?: string | string[] }> }) {
  const { actorId, current } = await requirePractice();
  if (!current.permissions.includes('BOOKING_CREATE')) redirect('/bookings');
  const sp = await searchParams;
  const customerId = typeof sp.customer === 'string' && UUID.test(sp.customer) ? sp.customer : null;
  const data = await withTenantTx({ actorId, tenantId: current.organization.id }, async (tx) => ({
    ...(await bookingFormData(tx)),
    customer: customerId ? await getCustomer(tx, customerId) : null,
  }));
  const t = await getTranslations('bookings');
  const tz = current.organization.timezone;

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-4 px-4 py-6">
        <Link href="/bookings" className="text-base text-brand underline">
          {t('back')}
        </Link>
        <h1 className="text-2xl font-bold">{t('new')}</h1>
        {data.offerings.length === 0 ? (
          <p className="text-base text-neutral-600">{t('noOfferings')}</p>
        ) : (
          <BookingForm
            tenantId={current.organization.id}
            timeZone={tz}
            today={todayInZone(tz)}
            offerings={data.offerings}
            priests={data.priests}
            canConfirm={current.permissions.includes('BOOKING_CONFIRM') || current.permissions.includes('BOOKING_CONFIRM_OWN')}
            initialCustomer={data.customer ? { id: data.customer.id, display_name: data.customer.display_name } : undefined}
          />
        )}
      </main>
    </>
  );
}
