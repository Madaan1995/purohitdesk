-- Ceremony catalog (docs/plan.md M1; names and durations PROPOSED, founder to correct).
-- Idempotent: safe to re-run. Punjabi names stay NULL until P1.
INSERT INTO app.ceremony_types (slug, name_en, name_hi, default_duration_min) VALUES
  ('griha-pravesh',       'Griha Pravesh',            'गृह प्रवेश',            180),
  ('satyanarayan-katha',  'Satyanarayan Katha',       'सत्यनारायण कथा',        120),
  ('mundan',              'Mundan Sanskar',           'मुंडन संस्कार',          90),
  ('namkaran',            'Namkaran Sanskar',         'नामकरण संस्कार',         60),
  ('annaprashan',         'Annaprashan',              'अन्नप्राशन',             60),
  ('upanayan',            'Upanayan (Janeu) Sanskar', 'उपनयन (जनेऊ) संस्कार',  180),
  ('vivah',               'Vivah',                    'विवाह',                 360),
  ('rudrabhishek',        'Rudrabhishek',             'रुद्राभिषेक',            120),
  ('havan',               'Havan',                    'हवन',                    90),
  ('bhoomi-pujan',        'Bhoomi Pujan',             'भूमि पूजन',              90),
  ('vastu-shanti',        'Vastu Shanti',             'वास्तु शांति',           180),
  ('navgrah-shanti',      'Navgrah Shanti',           'नवग्रह शांति',           180),
  ('kaal-sarp-dosh',      'Kaal Sarp Dosh Puja',      'कालसर्प दोष पूजा',       180),
  ('mahamrityunjay-jaap', 'Mahamrityunjay Jaap',      'महामृत्युंजय जाप',       240),
  ('sunderkand-path',     'Sunderkand Path',          'सुंदरकांड पाठ',          180),
  ('mata-ki-chowki',      'Mata ki Chowki',           'माता की चौकी',           180),
  ('jagran',              'Jagran',                   'जागरण',                 480),
  ('bhagwat-katha',       'Shrimad Bhagwat Katha',    'श्रीमद्भागवत कथा',       240),
  ('shraddh',             'Shraddh',                  'श्राद्ध',                120),
  ('terahvin',            'Terahvin',                 'तेरहवीं',                180)
ON CONFLICT (slug) DO UPDATE SET
  name_en              = EXCLUDED.name_en,
  name_hi              = EXCLUDED.name_hi,
  default_duration_min = EXCLUDED.default_duration_min;
