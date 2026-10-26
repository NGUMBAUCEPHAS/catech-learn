ALTER TABLE public.profiles ADD COLUMN account_status text NOT NULL DEFAULT 'active' CHECK (account_status IN ('active','suspended','disabled','pending_invitation'));
CREATE TABLE public.access_permissions (key text PRIMARY KEY, description text NOT NULL, scope text NOT NULL CHECK (scope IN ('platform','institution','personal')));
GRANT SELECT ON public.access_permissions TO authenticated; GRANT ALL ON public.access_permissions TO service_role;
ALTER TABLE public.access_permissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Permission catalog" ON public.access_permissions FOR SELECT TO authenticated USING (true);
CREATE TABLE public.access_roles (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), key text NOT NULL, name text NOT NULL, description text NOT NULL DEFAULT '', institution_id uuid REFERENCES public.institutions(id), predefined boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX access_roles_global_key ON public.access_roles(key) WHERE institution_id IS NULL;
CREATE UNIQUE INDEX access_roles_tenant_key ON public.access_roles(institution_id,key) WHERE institution_id IS NOT NULL;
GRANT SELECT ON public.access_roles TO authenticated; GRANT ALL ON public.access_roles TO service_role;
ALTER TABLE public.access_roles ENABLE ROW LEVEL SECURITY;
CREATE TABLE public.access_role_permissions (role_id uuid NOT NULL REFERENCES public.access_roles(id), permission_key text NOT NULL REFERENCES public.access_permissions(key), PRIMARY KEY(role_id,permission_key));
GRANT SELECT ON public.access_role_permissions TO authenticated; GRANT ALL ON public.access_role_permissions TO service_role;
ALTER TABLE public.access_role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.institution_memberships ADD COLUMN access_role_id uuid REFERENCES public.access_roles(id);
CREATE INDEX membership_access_role_idx ON public.institution_memberships(access_role_id);
CREATE FUNCTION public.account_is_active() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$ SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND account_status='active'); $$;
REVOKE ALL ON FUNCTION public.account_is_active() FROM PUBLIC,anon; GRANT EXECUTE ON FUNCTION public.account_is_active() TO authenticated,service_role;
CREATE OR REPLACE FUNCTION public.is_platform_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$ SELECT public.account_is_active() AND EXISTS(SELECT 1 FROM public.user_roles WHERE user_id=auth.uid() AND role='super_admin'); $$;
CREATE FUNCTION public.has_permission(_permission text, _institution_id uuid DEFAULT NULL) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT public.account_is_active() AND (
 EXISTS(SELECT 1 FROM public.user_roles u JOIN public.access_roles r ON r.key=u.role::text AND r.institution_id IS NULL JOIN public.access_role_permissions rp ON rp.role_id=r.id WHERE u.user_id=auth.uid() AND u.role='super_admin' AND rp.permission_key=_permission)
 OR (_institution_id IS NOT NULL AND EXISTS(SELECT 1 FROM public.institution_memberships m JOIN public.institutions i ON i.id=m.institution_id JOIN public.access_roles r ON (m.access_role_id=r.id OR (m.access_role_id IS NULL AND r.key=m.role::text AND r.institution_id IS NULL)) JOIN public.access_role_permissions rp ON rp.role_id=r.id JOIN public.access_permissions p ON p.key=rp.permission_key WHERE m.user_id=auth.uid() AND m.institution_id=_institution_id AND m.active AND i.status='active' AND (r.institution_id IS NULL OR r.institution_id=_institution_id) AND r.key<>'super_admin' AND p.scope<>'platform' AND rp.permission_key=_permission))
 ); $$;
REVOKE ALL ON FUNCTION public.has_permission(text,uuid) FROM PUBLIC,anon; GRANT EXECUTE ON FUNCTION public.has_permission(text,uuid) TO authenticated,service_role;
CREATE OR REPLACE FUNCTION public.has_institution_membership(_institution_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$ SELECT public.account_is_active() AND EXISTS(SELECT 1 FROM public.institution_memberships m JOIN public.institutions i ON i.id=m.institution_id WHERE m.institution_id=_institution_id AND m.user_id=auth.uid() AND m.active AND i.status='active'); $$;
CREATE OR REPLACE FUNCTION public.can_access_institution(_institution_id uuid,_manage boolean DEFAULT false) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$ SELECT public.has_permission(CASE WHEN _manage THEN 'institutions.update' ELSE 'institutions.view' END,_institution_id); $$;
ALTER POLICY "Institution summaries" ON public.institutions USING (public.has_permission('institutions.view',id));
ALTER POLICY "Own or managed memberships" ON public.institution_memberships USING (public.account_is_active() AND ((user_id=auth.uid() AND public.has_institution_membership(institution_id)) OR public.has_permission('users.view',institution_id)));
ALTER POLICY "Managed audit history" ON public.institution_audit_logs USING (public.has_permission('platform.audit_logs.view',NULL) OR public.has_permission('institution.audit_logs.view',institution_id));
CREATE POLICY "Active profile account" ON public.profiles AS RESTRICTIVE FOR ALL TO authenticated USING (public.account_is_active()) WITH CHECK (public.account_is_active());
CREATE POLICY "Active role account" ON public.user_roles AS RESTRICTIVE FOR SELECT TO authenticated USING (public.account_is_active());
CREATE POLICY "Visible roles" ON public.access_roles FOR SELECT TO authenticated USING (public.account_is_active() AND (institution_id IS NULL OR public.has_institution_membership(institution_id) OR public.has_permission('users.permissions.manage',institution_id)));
CREATE POLICY "Visible mappings" ON public.access_role_permissions FOR SELECT TO authenticated USING (EXISTS(SELECT 1 FROM public.access_roles r WHERE r.id=role_id));
CREATE FUNCTION public.my_access_context() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
 BEGIN
 IF NOT public.account_is_active() THEN RETURN jsonb_build_object('active',false,'platform',false,'permissions','[]'::jsonb); END IF;
 RETURN jsonb_build_object('active',true,'platform',public.has_permission('platform.dashboard.view',NULL),'permissions',(SELECT coalesce(jsonb_agg(key),'[]'::jsonb) FROM public.access_permissions WHERE public.has_permission(key,NULL)));
 END; $$;
REVOKE ALL ON FUNCTION public.my_access_context() FROM PUBLIC,anon; GRANT EXECUTE ON FUNCTION public.my_access_context() TO authenticated;
CREATE FUNCTION public.save_access_role(_institution_id uuid,_name text,_description text,_permissions text[],_id uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
 DECLARE rid uuid; old_scope uuid; built_in boolean; p text;
 BEGIN
 PERFORM pg_advisory_xact_lock(619732462);
 IF NOT public.has_permission('users.permissions.manage',_institution_id) OR NOT EXISTS(SELECT 1 FROM public.institutions WHERE id=_institution_id AND status='active') THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 IF char_length(btrim(_name)) NOT BETWEEN 2 AND 100 OR char_length(_description)>500 OR cardinality(_permissions)>100 THEN RAISE EXCEPTION 'Invalid role'; END IF;
 IF _id IS NOT NULL THEN
 SELECT institution_id,predefined INTO old_scope,built_in FROM public.access_roles WHERE id=_id FOR UPDATE;
 IF NOT FOUND OR old_scope IS DISTINCT FROM _institution_id OR built_in THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 IF EXISTS(SELECT 1 FROM public.institution_memberships WHERE user_id=auth.uid() AND access_role_id=_id AND active) THEN RAISE EXCEPTION 'Cannot change your own role' USING ERRCODE='42501'; END IF;
 FOR p IN SELECT permission_key FROM public.access_role_permissions WHERE role_id=_id LOOP
 IF NOT public.has_permission(p,_institution_id) THEN RAISE EXCEPTION 'Delegation denied' USING ERRCODE='42501'; END IF; END LOOP;
 END IF;
 FOREACH p IN ARRAY _permissions LOOP
 IF NOT EXISTS(SELECT 1 FROM public.access_permissions WHERE key=p AND scope='institution') OR NOT public.has_permission(p,_institution_id) THEN RAISE EXCEPTION 'Delegation denied' USING ERRCODE='42501'; END IF; END LOOP;
 IF _id IS NULL THEN INSERT INTO public.access_roles(key,name,description,institution_id) VALUES('custom_'||gen_random_uuid()::text,btrim(_name),btrim(_description),_institution_id) RETURNING id INTO rid;
 ELSE rid:=_id; UPDATE public.access_roles SET name=btrim(_name),description=btrim(_description),updated_at=now() WHERE id=rid; END IF;
 DELETE FROM public.access_role_permissions WHERE role_id=rid;
 INSERT INTO public.access_role_permissions(role_id,permission_key) SELECT rid,unnest(_permissions) ON CONFLICT DO NOTHING;
 INSERT INTO public.institution_audit_logs(institution_id,actor_id,action,target_id,details) VALUES(_institution_id,auth.uid(),'role_permissions_saved',rid,jsonb_build_object('name',_name,'permissions',_permissions));
 RETURN rid;
 END; $$;
REVOKE ALL ON FUNCTION public.save_access_role(uuid,text,text,text[],uuid) FROM PUBLIC,anon; GRANT EXECUTE ON FUNCTION public.save_access_role(uuid,text,text,text[],uuid) TO authenticated;
CREATE FUNCTION public.assign_access_role(_institution_id uuid,_user_id uuid,_role_id uuid,_active boolean DEFAULT true) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
 DECLARE rid uuid; r public.access_roles; p text;
 BEGIN
 PERFORM pg_advisory_xact_lock(619732462);
 IF _user_id=auth.uid() OR NOT public.has_permission('users.roles.assign',_institution_id) THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM public.institutions WHERE id=_institution_id AND status='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO r FROM public.access_roles WHERE id=_role_id;
 IF NOT FOUND OR r.key IN ('super_admin','support_agent') OR (r.institution_id IS NOT NULL AND r.institution_id<>_institution_id) THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 IF NOT public.has_permission('platform.users.manage',NULL) AND NOT EXISTS(SELECT 1 FROM public.institution_memberships WHERE institution_id=_institution_id AND user_id=_user_id) THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 FOR p IN SELECT rp.permission_key FROM public.access_role_permissions rp WHERE rp.role_id=_role_id UNION SELECT rp.permission_key FROM public.institution_memberships m JOIN public.access_roles old_r ON (m.access_role_id=old_r.id OR (m.access_role_id IS NULL AND old_r.key=m.role::text AND old_r.institution_id IS NULL)) JOIN public.access_role_permissions rp ON rp.role_id=old_r.id WHERE m.institution_id=_institution_id AND m.user_id=_user_id LOOP
 IF NOT EXISTS(SELECT 1 FROM public.access_permissions WHERE key=p AND scope='institution') OR NOT public.has_permission(p,_institution_id) THEN RAISE EXCEPTION 'Delegation denied' USING ERRCODE='42501'; END IF; END LOOP;
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=_user_id AND account_status='active') THEN RAISE EXCEPTION 'Account unavailable'; END IF;
 INSERT INTO public.institution_memberships(institution_id,user_id,role,access_role_id,active) VALUES(_institution_id,_user_id,CASE WHEN r.key='institution_admin' THEN 'institution_admin'::public.app_role WHEN r.key='teacher' THEN 'teacher'::public.app_role ELSE 'student'::public.app_role END,_role_id,_active) ON CONFLICT(institution_id,user_id) DO UPDATE SET role=EXCLUDED.role,access_role_id=EXCLUDED.access_role_id,active=EXCLUDED.active RETURNING id INTO rid;
 INSERT INTO public.institution_audit_logs(institution_id,actor_id,action,target_id,details) VALUES(_institution_id,auth.uid(),'access_role_assigned',_user_id,jsonb_build_object('role',r.name,'active',_active)); RETURN rid;
 END; $$;
REVOKE ALL ON FUNCTION public.assign_access_role(uuid,uuid,uuid,boolean) FROM PUBLIC,anon; GRANT EXECUTE ON FUNCTION public.assign_access_role(uuid,uuid,uuid,boolean) TO authenticated;
CREATE OR REPLACE FUNCTION public.assign_institution_member(_institution_id uuid,_user_id uuid,_role public.app_role,_active boolean DEFAULT true) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ DECLARE rid uuid; BEGIN SELECT id INTO rid FROM public.access_roles WHERE key=_role::text AND institution_id IS NULL; IF rid IS NULL THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF; RETURN public.assign_access_role(_institution_id,_user_id,rid,_active); END; $$;
CREATE FUNCTION public.set_account_status(_user_id uuid,_status text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN
 PERFORM pg_advisory_xact_lock(619732462);
 IF _user_id=auth.uid() OR NOT public.has_permission('platform.users.manage',NULL) OR EXISTS(SELECT 1 FROM public.user_roles WHERE user_id=_user_id AND role='super_admin') THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 IF _status NOT IN ('active','suspended','disabled') THEN RAISE EXCEPTION 'Invalid status'; END IF;
 UPDATE public.profiles SET account_status=_status WHERE id=_user_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Account unavailable'; END IF;
 INSERT INTO public.institution_audit_logs(actor_id,action,target_id,details) VALUES(auth.uid(),'account_status_changed',_user_id,jsonb_build_object('status',_status)); END; $$;
REVOKE ALL ON FUNCTION public.set_account_status(uuid,text) FROM PUBLIC,anon; GRANT EXECUTE ON FUNCTION public.set_account_status(uuid,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.institution_member_directory(_institution_id uuid) RETURNS TABLE(id uuid,user_id uuid,display_name text,role public.app_role,active boolean) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$ BEGIN
 IF NOT public.has_permission('users.view',_institution_id) THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT m.id,m.user_id,p.display_name,m.role,m.active FROM public.institution_memberships m JOIN public.profiles p ON p.id=m.user_id WHERE m.institution_id=_institution_id ORDER BY p.display_name; END; $$;
CREATE FUNCTION public.access_member_directory(_institution_id uuid) RETURNS TABLE(id uuid,user_id uuid,display_name text,role_id uuid,role_name text,active boolean) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$ BEGIN
 IF NOT public.has_permission('users.view',_institution_id) THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT m.id,m.user_id,p.display_name,r.id,r.name,m.active FROM public.institution_memberships m JOIN public.profiles p ON p.id=m.user_id JOIN public.access_roles r ON (m.access_role_id=r.id OR (m.access_role_id IS NULL AND r.key=m.role::text AND r.institution_id IS NULL)) WHERE m.institution_id=_institution_id ORDER BY p.display_name; END; $$;
REVOKE ALL ON FUNCTION public.access_member_directory(uuid) FROM PUBLIC,anon; GRANT EXECUTE ON FUNCTION public.access_member_directory(uuid) TO authenticated;
COMMENT ON COLUMN public.institution_memberships.role IS 'Compatibility label only when access_role_id is set; access_roles and access_role_permissions are the permission authority.';