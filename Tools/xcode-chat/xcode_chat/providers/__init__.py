"""Providers (agents) this tool can drive, keyed by the provider name Xcode stores in conversation.plist
(chatModelDefinitionId.providerIdentifier.builtIn._0)."""

from __future__ import annotations

from .base import Provider
from .claude import ClaudeProvider

PROVIDERS: dict[str, type[Provider]] = {provider.name: provider for provider in (ClaudeProvider,)}
DEFAULT_PROVIDER: str = ClaudeProvider.name


def get_provider(name: str | None) -> Provider | None:
    """The provider for an Xcode provider name, or None if it is not supported."""
    provider = PROVIDERS.get(name) if name else None
    return provider() if provider else None
