import { AppHeader } from '@/app/_components/AppHeader';
import { RescheduleForm } from '@/app/_components/RescheduleForm';
import { ownPriestProfile } from '@/app/_lib/booking-page';
import { getBooking, listPriests, UUID } from '@/app/_lib/bookings';
import { requirePractice } from '@/app/_lib/page-auth';
import { withTenantTx } from '@/db';
import { getTranslations } from 'next-intl/server';
import Link from 'next/link';
import { notFound, redirect } from 'next/navigation';

export default async function RescheduleBookingPage({ params }: { params: Promise<{ bookingId: string }> }) {
  const { bookingId } = await params;
  const { actorId, current } = await requirePractice();
  if (!UUID.test(bookingId)) notFound();
  const data = await withTenantTx({ actorId, tenantId: current.organization.id }, async (tx) => ({
    booking: await getBooking(tx, bookingId),
    priests: await listPriests(tx),
    profile: await ownPriestProfile(tx),
  }));
  const b = data.booking;
  if (!b) notFound();
  const lead = b.priests.find((p) => p.role === 'LEAD');
  const allowed =
    current.permissions.includes('BOOKING_CONFIRM') ||
    (current.permissions.includes('BOOKING_CONFIRM_OWN') && lead?.priest_profile_id === data.profile);
  if (b.status !== 'CONFIRMED' || !b.starts_at || !b.ends_at || !allowed) redirect(`/bookings/${bookingId}`);
  const t = await getTranslations('bookings');

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-4 px-4 py-6">
        <Link href={`/bookings/${bookingId}`} className="text-base text-brand underline">
          ← {b.booking_number}
        </Link>
        <h1 className="text-2xl font-bold">{t('rescheduleTitle')}</h1>
        <RescheduleForm
          tenantId={current.organization.id}
          booking={{ ...b, starts_at: b.starts_at, ends_at: b.ends_at }}
          priests={data.priests}
        />
      </main>
    </>
  );
}
