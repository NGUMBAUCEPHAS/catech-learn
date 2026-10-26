import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  navigate: vi.fn(), signUp: vi.fn(), signInWithPassword: vi.fn(), signInWithOAuth: vi.fn(),
}));
vi.mock('@tanstack/react-router', () => ({
  createFileRoute: () => (options: unknown) => ({ options }), useNavigate: () => mocks.navigate,
}));
vi.mock('@/components/AccountProvider', () => ({ useAccount: () => ({ user: null, loading: false }) }));
vi.mock('@/components/SiteNav', () => ({ SiteNav: () => null, SiteFooter: () => null }));
vi.mock('@/integrations/supabase/client', () => ({ supabase: { auth: mocks } }));
import { Route } from '@/routes/auth';

describe('Email-only account access', () => {
  beforeEach(() => { vi.clearAllMocks(); mocks.navigate.mockResolvedValue(undefined); });
  afterEach(cleanup);

  it('signs in using email and password without invoking social sign-in', async () => {
    mocks.signInWithPassword.mockResolvedValue({ error: null });
    const Auth = Route.options.component;
    if (!Auth) throw new Error('Missing auth screen');
    render(<Auth />);
    fireEvent.change(screen.getByLabelText('Email'), { target: { value: 'learner@example.com' } });
    fireEvent.change(screen.getByLabelText('Password'), { target: { value: 'Test-password-2026' } });
    fireEvent.submit(screen.getByRole('form', { name: 'Sign in' }));
    await waitFor(() => expect(mocks.navigate).toHaveBeenCalledWith({ to: '/dashboard' }));
    expect(mocks.signInWithPassword).toHaveBeenCalledWith({ email: 'learner@example.com', password: 'Test-password-2026' });
    expect(mocks.signInWithOAuth).not.toHaveBeenCalled();
  });

  it('opens the dashboard immediately after signup without an email confirmation step', async () => {
    mocks.signUp.mockResolvedValue({ data: { session: { user: { id: 'new-student' } } }, error: null });
    const Auth = Route.options.component;
    if (!Auth) throw new Error('Missing auth screen');
    render(<Auth />);
    fireEvent.click(screen.getByRole('button', { name: 'Create an account' }));
    fireEvent.change(screen.getByLabelText('Display name'), { target: { value: 'New Student' } });
    fireEvent.change(screen.getByLabelText('Email'), { target: { value: 'student@example.com' } });
    fireEvent.change(screen.getByLabelText('Password'), { target: { value: 'Test-password-2026' } });
    fireEvent.submit(screen.getByRole('form', { name: 'Create account' }));
    await waitFor(() => expect(mocks.navigate).toHaveBeenCalledWith({ to: '/dashboard' }));
    expect(mocks.signUp).toHaveBeenCalledWith({ email: 'student@example.com', password: 'Test-password-2026', options: { data: { display_name: 'New Student' } } });
    expect(mocks.signInWithPassword).not.toHaveBeenCalled();
  });
});