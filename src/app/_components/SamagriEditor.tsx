'use client';

import { MAX_SAMAGRI_ITEMS, type ProvidedBy } from '@/domain/catalog';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { useRef, useState } from 'react';
import { apiWrite } from './api-client';
import { FormStatus } from './FormStatus';

interface Row {
  key: string;
  name: string;
  quantity: string;
  provided_by: ProvidedBy;
}

interface Template {
  id: string;
  version: number;
  items: { name: string; quantity: string | null; provided_by: ProvidedBy }[];
}

/** One samagri list per offering: POST the first time, then PUT (If-Match) with the items in the shown order. */
export function SamagriEditor({ tenantId, offeringId, template }: { tenantId: string; offeringId: string; template: Template | null }) {
  const t = useTranslations('samagri');
  const tAll = useTranslations();
  const router = useRouter();
  const key = useRef(crypto.randomUUID());
  const [templateId, setTemplateId] = useState(template?.id ?? null);
  const [version, setVersion] = useState(template?.version ?? 1);
  const [rows, setRows] = useState<Row[]>(
    (template?.items ?? []).map((i) => ({ key: crypto.randomUUID(), name: i.name, quantity: i.quantity ?? '', provided_by: i.provided_by })),
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);

  const update = (index: number, patch: Partial<Row>) =>
    setRows((rs) => rs.map((r, i) => (i === index ? { ...r, ...patch } : r)));
  const move = (index: number, delta: number) =>
    setRows((rs) => {
      const next = [...rs];
      const [row] = next.splice(index, 1);
      next.splice(index + delta, 0, row);
      return next;
    });

  async function save() {
    if (busy) return;
    setBusy(true);
    setError(null);
    setSaved(null);
    const items = rows.map((r) => ({ name: r.name, quantity: r.quantity, provided_by: r.provided_by }));
    const result = templateId
      ? await apiWrite<Template>(`/samagri-templates/${templateId}`, {
          method: 'PUT', tenantId, idempotencyKey: key.current, ifMatch: version, body: { items },
        })
      : await apiWrite<Template>('/samagri-templates', {
          method: 'POST', tenantId, idempotencyKey: key.current, body: { offering_id: offeringId, items },
        });
    setBusy(false);
    if (!result.ok) {
      setError(tAll(`errors.${result.code}` as 'errors.INTERNAL'));
      return;
    }
    key.current = crypto.randomUUID();
    setTemplateId(result.data.id);
    setVersion(result.data.version);
    setSaved(t('saved'));
    router.refresh();
  }

  const small = 'min-h-11 min-w-11 rounded-lg border border-neutral-300 px-2 text-base disabled:opacity-40';
  return (
    <div className="flex flex-col gap-3">
      <p className="text-base text-neutral-600">{t('hint')}</p>
      {rows.length === 0 && <p className="text-base text-neutral-600">{t('empty')}</p>}
      <ol className="flex flex-col gap-3">
        {rows.map((row, i) => (
          <li key={row.key} className="flex flex-col gap-2 rounded-lg border border-neutral-200 p-3">
            <div className="flex gap-2">
              <input aria-label={t('item')} placeholder={t('item')} value={row.name} maxLength={120}
                onChange={(e) => update(i, { name: e.target.value })}
                className="min-h-11 min-w-0 flex-1 rounded-lg border border-neutral-300 px-3 text-base" />
              <input aria-label={t('quantity')} placeholder={t('quantity')} value={row.quantity} maxLength={60}
                onChange={(e) => update(i, { quantity: e.target.value })}
                className="min-h-11 w-24 rounded-lg border border-neutral-300 px-3 text-base" />
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <span className="text-base">{t('providedBy')}:</span>
              {(['FAMILY', 'PRIEST'] as const).map((who) => (
                <button key={who} type="button" aria-pressed={row.provided_by === who}
                  onClick={() => update(i, { provided_by: who })}
                  className="min-h-11 rounded-lg border border-neutral-300 px-3 text-base aria-pressed:border-brand aria-pressed:bg-brand aria-pressed:text-white">
                  {who === 'FAMILY' ? t('family') : t('priest')}
                </button>
              ))}
            </div>
            <div className="flex flex-wrap justify-end gap-2">
              <button type="button" onClick={() => move(i, -1)} disabled={i === 0} className={small}>{t('moveUp')}</button>
              <button type="button" onClick={() => move(i, 1)} disabled={i === rows.length - 1} className={small}>{t('moveDown')}</button>
              <button type="button" onClick={() => setRows((rs) => rs.filter((_, j) => j !== i))} className={small}>
                {t('remove')}
              </button>
            </div>
          </li>
        ))}
      </ol>
      <button type="button" disabled={rows.length >= MAX_SAMAGRI_ITEMS}
        onClick={() => setRows((rs) => [...rs, { key: crypto.randomUUID(), name: '', quantity: '', provided_by: 'FAMILY' }])}
        className="min-h-11 rounded-lg border border-brand px-4 text-base text-brand disabled:opacity-60">
        {t('addItem')}
      </button>
      <FormStatus error={error} saved={saved} />
      <button type="button" onClick={save} disabled={busy || rows.some((r) => !r.name.trim())}
        className="min-h-11 rounded-lg bg-brand px-4 text-lg font-semibold text-white disabled:opacity-60">
        {busy ? t('saving') : t('save')}
      </button>
    </div>
  );
}
