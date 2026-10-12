-- Source-backed Kanazawa Institute of Technology pilot configuration.
-- Checked 2026-07-10. Institution-specific values belong here, not in app logic.

insert into public.universities (
  id, config_key, name, normalized_name, name_en, aliases, prefecture,
  domain_hints, official_web_domain, timezone, status
)
values (
  '26a72fcd-6e61-5d0f-9c77-350762f2562f',
  'university:jp:kit',
  '金沢工業大学',
  public.normalize_course_text('金沢工業大学'),
  'Kanazawa Institute of Technology',
  array['KIT', 'Kanazawa Institute of Technology'],
  '石川県',
  '{}',
  'kanazawa-it.ac.jp',
  'Asia/Tokyo',
  'active'
)
on conflict (id) do update set
  config_key = excluded.config_key,
  name = excluded.name,
  normalized_name = excluded.normalized_name,
  name_en = excluded.name_en,
  aliases = excluded.aliases,
  prefecture = excluded.prefecture,
  domain_hints = excluded.domain_hints,
  official_web_domain = excluded.official_web_domain,
  timezone = excluded.timezone,
  status = excluded.status
where row(
  universities.config_key, universities.name, universities.normalized_name,
  universities.name_en, universities.aliases, universities.prefecture,
  universities.domain_hints, universities.official_web_domain,
  universities.timezone, universities.status
) is distinct from row(
  excluded.config_key, excluded.name, excluded.normalized_name,
  excluded.name_en, excluded.aliases, excluded.prefecture,
  excluded.domain_hints, excluded.official_web_domain,
  excluded.timezone, excluded.status
);

insert into public.campuses (
  id, university_id, config_key, name, normalized_name, is_main, status,
  source_url, source_checked_at
)
values
  ('5400e7bb-e9bf-5cbc-aaf8-5cfdade1ee74', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'campus:jp:kit:ougigaoka', '扇が丘', public.normalize_course_text('扇が丘'), true, 'active', 'https://www.kanazawa-it.ac.jp/about_kit/access.html', '2026-07-10'),
  ('a575fbd2-ee27-54a1-9775-f6ec464e369a', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'campus:jp:kit:yatsukaho-research', 'やつかほリサーチ', public.normalize_course_text('やつかほリサーチ'), false, 'active', 'https://www.kanazawa-it.ac.jp/about_kit/access.html', '2026-07-10'),
  ('d6533da3-43df-5444-a133-c4d7d5340f7a', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'campus:jp:kit:hakusanroku', '白山麓', public.normalize_course_text('白山麓'), false, 'active', 'https://www.kanazawa-it.ac.jp/about_kit/access.html', '2026-07-10'),
  ('72264f8f-a659-524a-94ea-506634a5bdd7', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'campus:jp:kit:toranomon', '虎ノ門', public.normalize_course_text('虎ノ門'), false, 'active', 'https://www.kanazawa-it.ac.jp/about_kit/access.html', '2026-07-10')
on conflict (id) do update set
  university_id = excluded.university_id,
  config_key = excluded.config_key,
  name = excluded.name,
  normalized_name = excluded.normalized_name,
  is_main = excluded.is_main,
  status = excluded.status,
  source_url = excluded.source_url,
  source_checked_at = excluded.source_checked_at
where row(
  campuses.university_id, campuses.config_key, campuses.name,
  campuses.normalized_name, campuses.is_main, campuses.status,
  campuses.source_url, campuses.source_checked_at
) is distinct from row(
  excluded.university_id, excluded.config_key, excluded.name,
  excluded.normalized_name, excluded.is_main, excluded.status,
  excluded.source_url, excluded.source_checked_at
);

insert into public.faculties (
  id, university_id, config_key, name, normalized_name, status,
  effective_from, effective_to, source_url, source_checked_at
)
values
  ('5eacc762-0ea3-5708-b210-5d88981235f4', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'faculty:jp:kit:2026:information-design', '情報デザイン学部', public.normalize_course_text('情報デザイン学部'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('05d5456a-2d10-5308-8bf6-14e1d1488fee', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'faculty:jp:kit:2026:media-informatics', 'メディア情報学部', public.normalize_course_text('メディア情報学部'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('5a34c1ab-9478-51b5-bbe1-cb1a709c90ba', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'faculty:jp:kit:2026:information-science-engineering', '情報理工学部', public.normalize_course_text('情報理工学部'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('bf5f0207-bdc3-5a8e-bd71-042996baf4e6', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'faculty:jp:kit:2026:bioscience-chemistry', 'バイオ・化学部', public.normalize_course_text('バイオ・化学部'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('7307c426-4659-5011-b810-726a7b2fa902', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'faculty:jp:kit:2026:engineering', '工学部', public.normalize_course_text('工学部'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('844c84ba-b531-52ed-bcfd-e7e104d6ab41', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'faculty:jp:kit:2026:architecture', '建築学部', public.normalize_course_text('建築学部'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10')
on conflict (id) do update set
  university_id = excluded.university_id,
  config_key = excluded.config_key,
  name = excluded.name,
  normalized_name = excluded.normalized_name,
  status = excluded.status,
  effective_from = excluded.effective_from,
  effective_to = excluded.effective_to,
  source_url = excluded.source_url,
  source_checked_at = excluded.source_checked_at
where row(
  faculties.university_id, faculties.config_key, faculties.name,
  faculties.normalized_name, faculties.status, faculties.effective_from,
  faculties.effective_to, faculties.source_url, faculties.source_checked_at
) is distinct from row(
  excluded.university_id, excluded.config_key, excluded.name,
  excluded.normalized_name, excluded.status, excluded.effective_from,
  excluded.effective_to, excluded.source_url, excluded.source_checked_at
);

insert into public.departments (
  id, university_id, faculty_id, config_key, name, normalized_name, status,
  effective_from, effective_to, source_url, source_checked_at
)
values
  ('a3008065-dfc4-5a34-a86d-d871da236347', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '5eacc762-0ea3-5708-b210-5d88981235f4', 'department:jp:kit:2026:management-information', '経営情報学科', public.normalize_course_text('経営情報学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('9fdd3a6e-de06-513c-85da-2fea10dc5525', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '5eacc762-0ea3-5708-b210-5d88981235f4', 'department:jp:kit:2026:environmental-design-innovation', '環境デザイン創成学科', public.normalize_course_text('環境デザイン創成学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('12c71b3f-a538-57c2-8d8f-6aca371250c5', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '05d5456a-2d10-5308-8bf6-14e1d1488fee', 'department:jp:kit:2026:media-informatics', 'メディア情報学科', public.normalize_course_text('メディア情報学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('6a21fa2a-102a-5e1c-8244-a872fd9bc1bf', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '05d5456a-2d10-5308-8bf6-14e1d1488fee', 'department:jp:kit:2026:psychology-information-design', '心理情報デザイン学科', public.normalize_course_text('心理情報デザイン学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('34b179bc-9629-595f-90f7-32173a4e8698', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '5a34c1ab-9478-51b5-bbe1-cb1a709c90ba', 'department:jp:kit:2026:information-engineering', '情報工学科', public.normalize_course_text('情報工学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('6de35efb-95ef-5a34-a8ce-b40da78ab1c6', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '5a34c1ab-9478-51b5-bbe1-cb1a709c90ba', 'department:jp:kit:2026:intelligent-information-systems', '知能情報システム学科', public.normalize_course_text('知能情報システム学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('2fec0b0b-5d3f-5610-bf16-afe761fac06f', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '5a34c1ab-9478-51b5-bbe1-cb1a709c90ba', 'department:jp:kit:2026:robotics', 'ロボティクス学科', public.normalize_course_text('ロボティクス学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('316ecb6b-68a2-54ae-a33e-23a656de68a4', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'bf5f0207-bdc3-5a8e-bd71-042996baf4e6', 'department:jp:kit:2026:environmental-applied-chemistry', '環境・応用化学科', public.normalize_course_text('環境・応用化学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('b781397f-ca14-5b9e-a812-00ef23688d08', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'bf5f0207-bdc3-5a8e-bd71-042996baf4e6', 'department:jp:kit:2026:life-applied-bioscience', '生命・応用バイオ学科', public.normalize_course_text('生命・応用バイオ学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('4b714ef6-caa7-5025-b119-5539e6866dd9', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '7307c426-4659-5011-b810-726a7b2fa902', 'department:jp:kit:2026:mechanical-engineering', '機械工学科', public.normalize_course_text('機械工学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('bf9110de-cc5c-5da4-9e4c-a71bdeab6eb1', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '7307c426-4659-5011-b810-726a7b2fa902', 'department:jp:kit:2026:advanced-mechanical-systems', '先進機械システム工学科', public.normalize_course_text('先進機械システム工学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('0c458081-5a6a-50ca-a25b-c9c05164fe8e', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '7307c426-4659-5011-b810-726a7b2fa902', 'department:jp:kit:2026:aerospace-engineering', '航空宇宙工学科', public.normalize_course_text('航空宇宙工学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('1d63e959-18eb-5658-a967-ba071f3ad42e', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '7307c426-4659-5011-b810-726a7b2fa902', 'department:jp:kit:2026:electrical-energy-systems', '電気エネルギーシステム工学科', public.normalize_course_text('電気エネルギーシステム工学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('9ddca4ac-fb2f-5cd3-9f83-cf15dbad694f', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '7307c426-4659-5011-b810-726a7b2fa902', 'department:jp:kit:2026:electronic-information-systems', '電子情報システム工学科', public.normalize_course_text('電子情報システム工学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('0597bb75-0904-5390-a1ed-b3bdf1a9c21f', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '7307c426-4659-5011-b810-726a7b2fa902', 'department:jp:kit:2026:environmental-civil-engineering', '環境土木工学科', public.normalize_course_text('環境土木工学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('f678adda-12c4-593a-8e5c-737f0bc65ca8', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '844c84ba-b531-52ed-bcfd-e7e104d6ab41', 'department:jp:kit:2026:architecture', '建築学科', public.normalize_course_text('建築学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10'),
  ('b512424e-defd-5388-b4ef-bdf527f04bf0', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '844c84ba-b531-52ed-bcfd-e7e104d6ab41', 'department:jp:kit:2026:architecture-design', '建築デザイン学科', public.normalize_course_text('建築デザイン学科'), 'active', '2026-04-01', '2027-03-31', 'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_1/page_5.html', '2026-07-10')
on conflict (id) do update set
  university_id = excluded.university_id,
  faculty_id = excluded.faculty_id,
  config_key = excluded.config_key,
  name = excluded.name,
  normalized_name = excluded.normalized_name,
  status = excluded.status,
  effective_from = excluded.effective_from,
  effective_to = excluded.effective_to,
  source_url = excluded.source_url,
  source_checked_at = excluded.source_checked_at
where row(
  departments.university_id, departments.faculty_id, departments.config_key,
  departments.name, departments.normalized_name, departments.status,
  departments.effective_from, departments.effective_to,
  departments.source_url, departments.source_checked_at
) is distinct from row(
  excluded.university_id, excluded.faculty_id, excluded.config_key,
  excluded.name, excluded.normalized_name, excluded.status,
  excluded.effective_from, excluded.effective_to,
  excluded.source_url, excluded.source_checked_at
);

insert into public.university_domains (
  id, university_id, config_key, domain, kind, verification_enabled,
  match_subdomains, cohort_start_academic_year, cohort_end_academic_year,
  effective_from, effective_to, status, source_url, source_checked_at
)
values (
  '9ff6e383-a629-53e1-b24c-0deb14a278f7',
  '26a72fcd-6e61-5d0f-9c77-350762f2562f',
  'domain:jp:kit:student:st.kanazawa-it.ac.jp:cohort-2026',
  'st.kanazawa-it.ac.jp',
  'student_email',
  true,
  false,
  2026,
  2026,
  '2026-04-01',
  null,
  'active',
  'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_2/list_1/page_5.html',
  '2026-07-10'
)
on conflict (id) do update set
  university_id = excluded.university_id,
  config_key = excluded.config_key,
  domain = excluded.domain,
  kind = excluded.kind,
  verification_enabled = excluded.verification_enabled,
  match_subdomains = excluded.match_subdomains,
  cohort_start_academic_year = excluded.cohort_start_academic_year,
  cohort_end_academic_year = excluded.cohort_end_academic_year,
  effective_from = excluded.effective_from,
  effective_to = excluded.effective_to,
  status = excluded.status,
  source_url = excluded.source_url,
  source_checked_at = excluded.source_checked_at
where row(
  university_domains.university_id, university_domains.config_key,
  university_domains.domain, university_domains.kind,
  university_domains.verification_enabled, university_domains.match_subdomains,
  university_domains.cohort_start_academic_year,
  university_domains.cohort_end_academic_year,
  university_domains.effective_from, university_domains.effective_to,
  university_domains.status, university_domains.source_url,
  university_domains.source_checked_at
) is distinct from row(
  excluded.university_id, excluded.config_key, excluded.domain, excluded.kind,
  excluded.verification_enabled, excluded.match_subdomains,
  excluded.cohort_start_academic_year, excluded.cohort_end_academic_year,
  excluded.effective_from, excluded.effective_to, excluded.status,
  excluded.source_url, excluded.source_checked_at
);

insert into public.terms (
  id, config_key, university_id, name, academic_year, start_date, end_date,
  instruction_start_date, instruction_end_date, term_type, is_template,
  status
)
values
  ('657f0bb3-7c10-510d-a8d2-133f0114a2f9', 'term:jp:kit:2026:first-semester', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '2026年度 前学期', 2026, '2026-04-01', '2026-09-30', null, null, 'semester', true, 'active'),
  ('512f0647-9bad-5af7-a66a-4d6070c0f294', 'term:jp:kit:2026:second-semester', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '2026年度 後学期', 2026, '2026-10-01', '2027-03-31', null, null, 'semester', true, 'active')
on conflict (id) do update set
  config_key = excluded.config_key,
  university_id = excluded.university_id,
  name = excluded.name,
  academic_year = excluded.academic_year,
  start_date = excluded.start_date,
  end_date = excluded.end_date,
  instruction_start_date = excluded.instruction_start_date,
  instruction_end_date = excluded.instruction_end_date,
  term_type = excluded.term_type,
  is_template = excluded.is_template,
  status = excluded.status
where row(
  terms.config_key, terms.university_id, terms.name, terms.academic_year,
  terms.start_date, terms.end_date, terms.instruction_start_date,
  terms.instruction_end_date, terms.term_type, terms.is_template, terms.status
) is distinct from row(
  excluded.config_key, excluded.university_id, excluded.name,
  excluded.academic_year, excluded.start_date, excluded.end_date,
  excluded.instruction_start_date, excluded.instruction_end_date,
  excluded.term_type, excluded.is_template, excluded.status
);

-- is_default means recommended within this campus/year scope; onboarding still
-- requires an explicit template-set choice and never auto-applies it.
insert into public.period_template_sets (
  id, university_id, campus_id, config_key, name, academic_year, effective_from,
  effective_to, is_default, status, source_url, source_checked_at
)
values (
  '253ef732-d142-5abc-bb3a-17a12ff3820b',
  '26a72fcd-6e61-5d0f-9c77-350762f2562f',
  '5400e7bb-e9bf-5cbc-aaf8-5cfdade1ee74',
  'period-template:jp:kit:main-standard:2026',
  '2026年度 主時間割（標準）',
  2026,
  '2026-04-01',
  '2027-03-31',
  true,
  'active',
  'https://www.kanazawa-it.ac.jp/campus_guide/2026/chapter_3/list_1/page_1.html',
  '2026-07-10'
)
on conflict (id) do update set
  university_id = excluded.university_id,
  campus_id = excluded.campus_id,
  config_key = excluded.config_key,
  name = excluded.name,
  academic_year = excluded.academic_year,
  effective_from = excluded.effective_from,
  effective_to = excluded.effective_to,
  is_default = excluded.is_default,
  status = excluded.status,
  source_url = excluded.source_url,
  source_checked_at = excluded.source_checked_at
where row(
  period_template_sets.university_id, period_template_sets.campus_id,
  period_template_sets.config_key,
  period_template_sets.name, period_template_sets.academic_year,
  period_template_sets.effective_from, period_template_sets.effective_to,
  period_template_sets.is_default, period_template_sets.status,
  period_template_sets.source_url, period_template_sets.source_checked_at
) is distinct from row(
  excluded.university_id, excluded.campus_id, excluded.config_key, excluded.name,
  excluded.academic_year, excluded.effective_from, excluded.effective_to,
  excluded.is_default, excluded.status, excluded.source_url,
  excluded.source_checked_at
);

insert into public.period_templates (
  id, template_set_id, university_id, day_of_week, period_no,
  start_time, end_time
)
values
  ('9bee50ef-7387-5e03-b72e-c454d5745dfc', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 1, 1, '08:40', '10:20'),
  ('615919c2-7996-5c03-baf8-570f78063b71', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 1, 2, '10:35', '12:15'),
  ('c9832c96-865b-5820-9fc7-1c3a19ea09c9', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 1, 3, '13:15', '14:55'),
  ('609c283b-c69d-5814-a866-3e599880bad2', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 1, 4, '15:10', '16:50'),
  ('1a0a24e6-3d88-503f-8342-ff94380caa80', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 1, 5, '17:05', '18:45'),
  ('badf64ff-a265-5132-93fd-f49ef80e6d4d', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 2, 1, '08:40', '10:20'),
  ('e0b5c4cb-801e-50c7-a3b4-7004670e8266', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 2, 2, '10:35', '12:15'),
  ('17ba3b5c-5969-57b1-9a53-8c0ae57da12f', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 2, 3, '13:15', '14:55'),
  ('181bfdf0-34a0-5787-a420-ff454b591b5b', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 2, 4, '15:10', '16:50'),
  ('9ee2786d-c8d7-5cbe-ab7a-f7398da124d1', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 2, 5, '17:05', '18:45'),
  ('2a38074b-a624-527f-a00f-3392ee1e3f5c', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 3, 1, '08:40', '10:20'),
  ('b2d9aee0-1c53-5ddb-8abd-0f1942ad04d4', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 3, 2, '10:35', '12:15'),
  ('2a8a506e-f74f-5ff3-a905-1a11b29d061a', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 3, 3, '13:15', '14:55'),
  ('94a5c931-6509-54cf-b7f2-a557ed30d3a1', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 3, 4, '15:10', '16:50'),
  ('2e3ad5fb-9375-58b2-a820-9b5ac30b6b48', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 3, 5, '17:05', '18:45'),
  ('16034773-1cf1-5f4e-92d6-6a3c45fb163d', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 4, 1, '08:40', '10:20'),
  ('28aea62d-c2cc-5f1f-ae0e-4f0a577b3ceb', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 4, 2, '10:35', '12:15'),
  ('68ff22ce-273b-5419-b03f-2303072570f7', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 4, 3, '13:15', '14:55'),
  ('5b26f79b-d10f-5b79-90c0-6dfff8a04fea', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 4, 4, '15:10', '16:50'),
  ('2c8c69eb-13ab-5af0-8a98-b1610fc41b7d', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 4, 5, '17:05', '18:45'),
  ('04edd4e9-dfaa-578b-997c-1e2afa7ff75a', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 5, 1, '08:40', '10:20'),
  ('9668b952-00d0-597d-bec1-1a57243001a7', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 5, 2, '10:35', '12:15'),
  ('9027cb5e-67a5-5f03-b893-d487917b352f', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 5, 3, '13:15', '14:55'),
  ('f0db8de1-527f-5eb9-a92c-54a58781c406', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 5, 4, '15:10', '16:50'),
  ('65053d13-850f-5551-b0a8-e7b223746e07', '253ef732-d142-5abc-bb3a-17a12ff3820b', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 5, 5, '17:05', '18:45')
on conflict (id) do update set
  template_set_id = excluded.template_set_id,
  university_id = excluded.university_id,
  day_of_week = excluded.day_of_week,
  period_no = excluded.period_no,
  start_time = excluded.start_time,
  end_time = excluded.end_time
where row(
  period_templates.template_set_id, period_templates.university_id,
  period_templates.day_of_week, period_templates.period_no,
  period_templates.start_time, period_templates.end_time
) is distinct from row(
  excluded.template_set_id, excluded.university_id, excluded.day_of_week,
  excluded.period_no, excluded.start_time, excluded.end_time
);
