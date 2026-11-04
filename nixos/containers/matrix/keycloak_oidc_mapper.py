"""Keycloak OIDC mapping + admin sync for Matrix Synapse.

Keycloak's `groups` client scope puts a flat list of group names in the ID
token (claim ``groups``). Membership of ``matrix_admin`` makes the user a
Synapse server admin; leaving the group removes it. Checked on every SSO
login, not only at registration.
"""

from __future__ import annotations

import logging
from typing import Any, Dict, Optional

from synapse.handlers.oidc import JinjaOidcMappingProvider, UserInfo, Token, UserAttributeDict
from synapse.module_api import ModuleApi

logger = logging.getLogger(__name__)

GROUPS_CLAIM = "groups"
_pending_admin_by_sub: Dict[str, bool] = {}


def _has_admin_group(userinfo: UserInfo, admin_group: str) -> bool:
    groups = userinfo.get(GROUPS_CLAIM) or []
    if isinstance(groups, str):
        groups = [groups]
    if not isinstance(groups, (list, tuple)):
        return False
    # Accept "/matrix_admin" too, in case the mapper is ever set to full paths.
    return any(isinstance(g, str) and g.lstrip("/") == admin_group for g in groups)


class KeycloakOidcMappingProvider(JinjaOidcMappingProvider):
    """Jinja OIDC mapper that records the Keycloak admin group for post-login sync."""

    _admin_group: str = "matrix_admin"

    @staticmethod
    def parse_config(config: dict) -> Any:
        parsed = JinjaOidcMappingProvider.parse_config(
            {k: v for k, v in config.items() if k != "admin_group"}
        )
        KeycloakOidcMappingProvider._admin_group = config.get("admin_group", "matrix_admin")
        return parsed

    async def map_user_attributes(
        self, userinfo: UserInfo, token: Token, failures: int
    ) -> UserAttributeDict:
        result = await super().map_user_attributes(userinfo, token, failures)
        self._record_admin(userinfo)
        return result

    def _record_admin(self, userinfo: UserInfo) -> None:
        sub = self.get_remote_user_id(userinfo)
        _pending_admin_by_sub[sub] = _has_admin_group(userinfo, self._admin_group)

    async def get_extra_attributes(self, userinfo: UserInfo, token: Token) -> Dict[str, Any]:
        # map_user_attributes only runs when a user is first registered; this runs on
        # every SSO login, so group changes in Keycloak reach existing users too.
        self._record_admin(userinfo)
        return await super().get_extra_attributes(userinfo, token)


class KeycloakAdminModule:
    """Synapse module: apply the pending admin flag after an OIDC login."""

    def __init__(self, config: dict, api: ModuleApi) -> None:
        self._api = api
        self._admin_group = config.get("admin_group", "matrix_admin")
        api.register_account_validity_callbacks(on_user_login=self._on_user_login)

    @staticmethod
    def parse_config(config: dict) -> dict:
        return config

    async def _on_user_login(
        self,
        user_id: str,
        auth_provider_type: Optional[str],
        auth_provider_id: Optional[str],
    ) -> None:
        # SSO logins arrive as type "m.login.sso" with the IdP id ("oidc-keycloak").
        if auth_provider_type != "m.login.sso" or not auth_provider_id:
            return

        try:
            # (auth_provider, external_id) pairs recorded at SSO registration.
            external_ids = await self._api._store.get_external_ids_by_user(user_id)
        except Exception:
            logger.exception("Keycloak OIDC: could not read external ids for %s", user_id)
            return
        is_admin = None
        for provider, external_id in external_ids:
            if provider == auth_provider_id and external_id in _pending_admin_by_sub:
                is_admin = _pending_admin_by_sub.pop(external_id)
                break
        if is_admin is None:
            return

        try:
            current = await self._api.is_user_admin(user_id)
            if current != is_admin:
                await self._api.set_user_admin(user_id, is_admin)
                logger.info(
                    "Keycloak OIDC: set admin=%s for %s (group %s)",
                    is_admin,
                    user_id,
                    self._admin_group,
                )
        except Exception:
            logger.exception(
                "Keycloak OIDC: failed to sync admin=%s for %s",
                is_admin,
                user_id,
            )
