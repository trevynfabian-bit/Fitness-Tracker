-- ============================================================================
-- 20260904110000_phase3_import_storage.sql
-- Phase 3: the private bucket every uploaded import file is retained in.
--
-- v2 section 5.2: the client requests a signed upload URL and PUTs directly to
-- storage; the API never sees the bytes. v3 section 2.4: retention is
-- indefinite, the path is {user_id}/{import_id}/{filename}, and a file whose
-- import contains Tier R data is non-deletable while that import is active.
-- PRD section 13 makes retention a product requirement, not an optimisation.
--
-- The bucket is private. Access is by signed URL only, and the object policies
-- below additionally confine every authenticated user to their own top-level
-- folder, which is their user id. No update or delete policy exists: an
-- uploaded file is immutable and is not removable through the client API.
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('imports', 'imports', false)
on conflict (id) do update set public = false;

create policy "imports_insert_own_folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'imports'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "imports_select_own_folder"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'imports'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
