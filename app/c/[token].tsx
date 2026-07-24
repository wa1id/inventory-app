import { useEffect, useState } from 'react';
import { useLocalSearchParams, useRouter } from 'expo-router';

import { useRepositories } from '@/providers/DatabaseProvider';
import { logEvent } from '@/services/telemetry';
import { strings } from '@/i18n/strings';
import { EmptyState } from '@/ui/components/EmptyState';
import { LoadingState, Screen } from '@/ui/components/Screen';

/**
 * Deep-link target for a scanned QR label (`inventory://c/<token>`).
 *
 * QR payloads carry a URL so the *system* camera can open the app too, not just
 * the in-app Scan tab. This route resolves the token through the same
 * repository the scanner uses and redirects to the bound container.
 */
export default function QrDeepLinkScreen() {
  const { token } = useLocalSearchParams<{ token: string }>();
  const repos = useRepositories();
  const router = useRouter();
  const [outcome, setOutcome] = useState<'resolving' | 'unknown' | 'invalid'>('resolving');

  useEffect(() => {
    let cancelled = false;

    (async () => {
      const result = await repos.qr.resolveScan(token ?? '');
      if (cancelled) return;

      if (result.kind === 'bound') {
        logEvent('qr_deeplink', { outcome: 'bound' });
        router.replace(`/container/${result.container.id}`);
        return;
      }

      logEvent('qr_deeplink', { outcome: result.kind });
      setOutcome(result.kind === 'unknown' ? 'unknown' : 'invalid');
    })();

    return () => {
      cancelled = true;
    };
  }, [token, repos, router]);

  if (outcome === 'resolving') {
    return (
      <Screen>
        <LoadingState label="Opening that container…" />
      </Screen>
    );
  }

  if (outcome === 'unknown') {
    return (
      <Screen>
        <EmptyState
          icon="🏷️"
          title={strings.scan.unknownTitle}
          body="This label isn't linked to a container yet. Scan it from the Scan tab to link it."
          actionLabel="Open the scanner"
          onAction={() => router.replace('/scan')}
        />
      </Screen>
    );
  }

  return (
    <Screen>
      <EmptyState
        icon="❓"
        title={strings.scan.invalidTitle}
        body={strings.scan.invalidBody}
        actionLabel="Go to spaces"
        onAction={() => router.replace('/')}
      />
    </Screen>
  );
}
