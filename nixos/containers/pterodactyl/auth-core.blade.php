@extends('templates/wrapper', [
    'css' => ['body' => 'bg-neutral-900']
])

@section('above-container')
    @if(request()->is('auth/login'))
        <div style="max-width:28rem;margin:2rem auto 0;padding:0 1rem;text-align:center;">
            <a href="/oauth2/start?rd=/"
               style="display:block;width:100%;padding:0.875rem 1rem;background:#0e4688;color:#fff;border-radius:0.375rem;font-weight:600;text-decoration:none;font-size:1.125rem;line-height:1.5;">
                Sign in with Zitadel
            </a>
            <p style="margin-top:0.75rem;color:#a3a3a3;font-size:0.75rem;text-transform:uppercase;letter-spacing:0.05em;">
                or use local credentials below (break-glass)
            </p>
        </div>
    @endif
@endsection

@section('container')
    <div id="app"></div>
@endsection
