import { createFileRoute, useNavigate } from '@tanstack/react-router';
import { useEffect, useState } from 'react';
import { Eye, EyeOff, LogIn, Mail, UserPlus } from 'lucide-react';
import { supabase } from '@/integrations/supabase/client';
import { useAccount } from '@/components/AccountProvider';
import { SiteNav, SiteFooter } from '@/components/SiteNav';
import { Button } from '@/components/ui/button';

export const Route = createFileRoute('/auth')({
  head: () => ({ meta: [
    { title: 'Sign in — CATECH Learn' }, { name: 'description', content: 'Sign in or create your CATECH Learn account.' },
    { property: 'og:title', content: 'Sign in to CATECH Learn' }, { property: 'og:description', content: 'Access your learning account.' },
    { property: 'og:type', content: 'website' }, { name: 'twitter:card', content: 'summary' },
  ] }), component: Auth,
});
function Auth() {
  const [mode, setMode] = useState<'signin' | 'signup' | 'forgot'>('signin');
  const [email, setEmail] = useState(''); const [password, setPassword] = useState(''); const [name, setName] = useState('');
  const [busy, setBusy] = useState(false); const [error, setError] = useState(''); const [message, setMessage] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const { user, loading } = useAccount(); const navigate = useNavigate();
  useEffect(() => { if (!loading && user) void navigate({ to: '/dashboard', replace: true }); }, [user, loading, navigate]);
  function switchMode(next: typeof mode) { setMode(next); setError(''); setMessage(''); setPassword(''); setShowPassword(false); }
  async function submit(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); setError(''); setMessage('');
    try {
      if (mode === 'forgot') {
        const result = await supabase.auth.resetPasswordForEmail(email, { redirectTo: `${window.location.origin}/reset-password` });
        if (result.error) throw result.error;
        setMessage('Check your email for a password reset link.');
      } else if (mode === 'signup') {
        const result = await supabase.auth.signUp({ email: email.trim(), password, options: { data: { display_name: name.trim() } } });
        if (result.error) throw result.error;
        if (!result.data.session) {
          const signIn = await supabase.auth.signInWithPassword({ email: email.trim(), password });
          if (signIn.error) throw signIn.error;
        }
        await navigate({ to: '/dashboard' });
      } else {
        const result = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (result.error) throw result.error;
        await navigate({ to: '/dashboard' });
      }
    } catch (err) { setError(err instanceof Error ? err.message : 'Unable to continue. Please try again.'); } finally { setBusy(false); }
  }
  const inputClass = 'mt-2 w-full rounded-md border border-input bg-card px-4 py-3 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20 disabled:opacity-60';
  return <div className="flex min-h-screen flex-col"><SiteNav /><main className="mx-auto w-full max-w-md flex-1 px-5 py-12 sm:py-16">
    <div className="border-l-4 border-accent pl-4"><p className="text-sm font-semibold text-primary">CATECH LEARN</p><h1 className="mt-2 text-3xl font-bold">{mode === 'signup' ? 'Create your account' : mode === 'forgot' ? 'Reset your password' : 'Welcome back'}</h1></div>
    <form onSubmit={submit} className="mt-8 space-y-5" aria-label={mode === 'signup' ? 'Create account' : mode === 'forgot' ? 'Password recovery' : 'Sign in'}>
      {mode === 'signup' && <label className="block text-sm font-semibold">Display name<input required disabled={busy} maxLength={100} value={name} autoComplete="name" onChange={e => setName(e.target.value)} className={inputClass} /></label>}
      <label className="block text-sm font-semibold">Email<input type="email" required disabled={busy} value={email} autoComplete="email" onChange={e => setEmail(e.target.value)} className={inputClass} /></label>
      {mode !== 'forgot' && <div><label htmlFor="account-password" className="block text-sm font-semibold">Password</label><div className="relative"><input id="account-password" type={showPassword ? 'text' : 'password'} required disabled={busy} minLength={mode === 'signup' ? 8 : undefined} value={password} autoComplete={mode === 'signup' ? 'new-password' : 'current-password'} onChange={e => setPassword(e.target.value)} className={`${inputClass} pr-12`} /><Button type="button" variant="ghost" size="icon" disabled={busy} className="absolute right-1 top-3" aria-label={showPassword ? 'Hide password' : 'Show password'} title={showPassword ? 'Hide password' : 'Show password'} onClick={() => setShowPassword(value => !value)}>{showPassword ? <EyeOff /> : <Eye />}</Button></div></div>}
      {error && <p role="alert" className="text-sm text-destructive">{error}</p>}{message && <p role="status" className="text-sm text-primary">{message}</p>}
      <Button type="submit" className="w-full" size="lg" disabled={busy}>{mode === 'forgot' ? <Mail /> : mode === 'signup' ? <UserPlus /> : <LogIn />}{busy ? 'Please wait…' : mode === 'signup' ? 'Create account' : mode === 'forgot' ? 'Send reset link' : 'Sign in'}</Button>
    </form>
    <div className="mt-6 flex flex-wrap justify-between gap-2 border-t border-border pt-4"><Button variant="link" disabled={busy} onClick={() => switchMode(mode === 'signup' || mode === 'forgot' ? 'signin' : 'signup')}>{mode === 'signin' ? 'Create an account' : 'Back to sign in'}</Button>{mode === 'signin' && <Button variant="link" disabled={busy} onClick={() => switchMode('forgot')}>Forgot password?</Button>}</div>
  </main><SiteFooter /></div>;
}