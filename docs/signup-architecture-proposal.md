# Self-Serve Signup Gap Analysis & Architecture Proposal

## 1. Current State Map
With the recent changes in commit `0caaf3d`, the user acquisition flow has transitioned from a manual waitlist to a direct login approach:

1. **Visitor Lands on Landing Page:** The user visits the `savvy-landing` site (`index.html`).
2. **Click CTA:** The primary CTAs have been updated to point directly to `https://app.withsavvy.ai/#sign-up`.
3. **Clerk Auth Flow:** The `savvy-frontend` application catches the `#sign-up` hash in `src/AuthGate.tsx` and renders the Clerk `<SignUp />` component.
4. **App Initialization:** Upon successful Clerk registration, the user is authenticated and enters the React app (`App.tsx`).
5. **Lazy Provisioning:** The frontend makes initial data calls (e.g., `/api/billing/status`). In `savvy-backend`, the `requireAuth` middleware validates the Clerk JWT, and the `checkAccess` billing service lazily intercepts the request, calling `getOrCreateBilling`. This implicitly creates a `user_billing` row in Supabase and provisions a 30-day trial.

**Can a new user self-register end-to-end?**
**Yes.** The system does not explicitly block them. Because of the lazy-provisioning logic in `getOrCreateBilling`, any user who signs up via Clerk will automatically receive a 30-day trial and be granted access to the core application upon their first authenticated API request.

---

## 2. Remaining Gaps to Full Self-Serve Signup

While users can technically get into the app, there are significant gaps in the architecture that prevent a robust, production-ready self-serve pipeline:

- **Missing Backend Webhook (No Single Source of Truth):** `savvy-backend` has no Clerk webhook receiver. The backend only learns a user exists when they make their first API call. If a user signs up but closes the tab before the app loads, they exist in Clerk but not in our database.
- **No Welcome/Marketing Automation:** Because there's no backend trigger upon signup, we currently have no way to reliably send a welcome email, push the user into a drip campaign (e.g., Customer.io, Loops), or track signup conversions reliably on the backend.
- **Loss of Phone Number Collection:** The old waitlist explicitly collected phone numbers. Savvy's core value relies on SMS notifications (as seen in `/api/sms`). If the Clerk `<SignUp />` component is not configured to require a phone number, we lose the ability to send SMS alerts until the user manually opts in via the app's settings.
- **Obsolete Landing Backend:** The `savvy-landing/backend` service, previously used to capture waitlist submissions and Twilio verifications, is now effectively dead code but remains in the repository, adding technical debt and confusion.
- **Client-Side Coupon Fragility:** Launch/referral coupons are handled by the frontend reading `?coupon=` from the URL, saving it to `localStorage`, and manually calling `/api/billing/redeem-coupon`. If this client-side logic fails or the user switches devices, the coupon is lost.

---

## 3. Architecture Options & Tradeoffs

### Option A: Clerk Webhooks as Single Source of Truth (Recommended)
Configure Clerk to send a `user.created` webhook to `savvy-backend`.
- **How it works:** A new endpoint `POST /api/webhooks/clerk` is added to `savvy-backend`. When a user signs up, Clerk sends an event. The backend creates the `user_billing` record, extracts the email/phone, syncs them to Supabase (or marketing tools), and sends a welcome email.
- **Tradeoffs:**
  - *Pros:* 100% reliable. The backend is the single source of truth. Allows instant welcome emails and analytics tracking. Removes reliance on frontend lazy-provisioning.
  - *Cons:* Requires setting up `ngrok` or similar for local development to receive webhooks from Clerk.

### Option B: Decentralized Lazy-Load (Status Quo + Polish)
Keep the current lazy-provisioning system but add an explicit initialization step.
- **How it works:** Add a `POST /api/onboarding/init` endpoint. The `savvy-frontend` calls this immediately after Clerk auth completes. This endpoint handles trial provisioning, welcome emails, and coupon redemption.
- **Tradeoffs:**
  - *Pros:* Easier to test locally (no webhooks). Fits the current lazy-load pattern.
  - *Cons:* Client-side network requests can be interrupted (e.g., user closes the browser). You end up with orphaned Clerk users that don't exist in Supabase.

### Option C: Custom Auth Wrapper in Backend
Build a proxy signup API in `savvy-backend`.
- **How it works:** The landing page points to a custom signup form in `savvy-frontend` that hits `POST /api/auth/register`. The backend calls the Clerk Backend SDK to create the user, sets up Supabase, and returns a session.
- **Tradeoffs:**
  - *Pros:* Ultimate control over the signup payload (can enforce phone number + coupon synchronously).
  - *Cons:* Abandons Clerk's drop-in UI component. High engineering effort for little architectural gain.

---

## 4. Implementation Checklist (Sized for Work Orders)

The following units should be executed in order to implement **Option A**:

### Unit 1: Configure Clerk Webhook Receiver in Backend
- **Target Files:**
  - `savvy-backend/src/routes/webhooks/clerk.ts` [NEW]
  - `savvy-backend/src/index.ts`
  - `savvy-backend/src/utils/config.ts`
- **Acceptance Criteria:**
  - Add `CLERK_WEBHOOK_SECRET` to `config.ts`.
  - Create the Clerk webhook receiver route, utilizing the `svix` library to verify the webhook signature.
  - Handle the `user.created` event: gracefully call `ensureBilling(userId)` to provision the 30-day trial synchronously.
  - Mount the route in `index.ts` *before* the JSON body parser if `svix` requires the raw body (similar to Stripe).

### Unit 2: Implement Welcome Email & CRM Sync
- **Target Files:**
  - `savvy-backend/src/services/user-service.ts` [NEW]
  - `savvy-backend/src/routes/webhooks/clerk.ts`
- **Acceptance Criteria:**
  - Within the `user.created` webhook handler, parse the primary email address and phone number (if available) from the Clerk payload.
  - Integrate with the existing `email.ts` utilities or a marketing provider to send the standard "Welcome to Savvy" email.
  - Create a resilient structure (e.g., `try/catch` block) so that if the email fails, the webhook still returns a `200 OK` and doesn't continually retry user creation.

### Unit 3: Enforce Phone Number Collection
- **Target Files:**
  - External: Clerk Dashboard (No code changes needed, configuration only).
  - `savvy-frontend/src/AuthGate.tsx`
- **Acceptance Criteria:**
  - Clerk Dashboard must be configured to require "Phone Number" upon sign-up.
  - Update `AuthGate.tsx` or related onboarding screens to ensure that if a user sneaks by without a phone number (e.g., via OAuth), they are prompted to add it for SMS notifications.

### Unit 4: Decommission Legacy Landing Backend
- **Target Files:**
  - `savvy-landing/backend/` [DELETE ENTIRE DIRECTORY]
  - `savvy-landing/package.json`
- **Acceptance Criteria:**
  - Remove the `savvy-landing/backend` folder completely.
  - Remove all waitlist-related dependencies and start scripts from the root `savvy-landing/package.json`.
  - Ensure the landing page builds cleanly without backend dependencies.

### Unit 5: Resilient Coupon Redemption
- **Target Files:**
  - `savvy-frontend/src/AuthGate.tsx`
  - `savvy-frontend/src/App.tsx`
- **Acceptance Criteria:**
  - If a user signs up with a coupon in `localStorage`, attempt to redeem it.
  - If the redemption fails, safely catch the error and surface a non-blocking toast notification rather than breaking the application flow.
  - Pass the coupon directly to the Clerk `<SignUp />` component using unsafe metadata (if supported) so the webhook can process it centrally, deprecating the client-side `/api/billing/redeem-coupon` initial call.
