import { AppHeader } from '@/app/_components/AppHeader';
import { BookingForm } from '@/app/_components/BookingForm';
import { bookingFormData } from '@/app/_lib/booking-page';
import { getBooking, UUID } from '@/app/_lib/bookings';
import { requirePractice } from '@/app/_lib/page-auth';
import { withTenantTx } from '@/db';
import { todayInZone } from '@/domain/time';
import { getTranslations } from 'next-intl/server';
import Link from 'next/link';
import { notFound, redirect } from 'next/navigation';

export default async function EditBookingPage({ params }: { params: Promise<{ bookingId: string }> }) {
  const { bookingId } = await params;
  const { actorId, current } = await requirePractice();
  if (!UUID.test(bookingId)) notFound();
  if (!current.permissions.includes('BOOKING_EDIT')) redirect(`/bookings/${bookingId}`);
  const data = await withTenantTx({ actorId, tenantId: current.organization.id }, async (tx) => {
    const booking = await getBooking(tx, bookingId);
    return booking ? { booking, ...(await bookingFormData(tx, booking.offering.id)) } : null;
  });
  if (!data) notFound();
  const t = await getTranslations('bookings');

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-4 px-4 py-6">
        <Link href={`/bookings/${bookingId}`} className="text-base text-brand underline">
          ← {data.booking.booking_number}
        </Link>
        <h1 className="text-2xl font-bold">{t('edit')}</h1>
        <BookingForm
          tenantId={current.organization.id}
          timeZone={data.booking.timezone}
          today={todayInZone(data.booking.timezone)}
          offerings={data.offerings}
          priests={data.priests}
          canConfirm={false}
          booking={data.booking}
        />
      </main>
    </>
  );
}
