"""Zitadel OIDC mapping + admin sync for Matrix Synapse.

Maps Zitadel project role ``matrix_admin`` (claim ``urn:zitadel:iam:org:project:roles``)
to Synapse server admin on each SSO login.
"""

from __future__ import annotations

import logging
from typing import Any, Dict, Optional

from synapse.handlers.oidc import JinjaOidcMappingProvider, UserInfo, Token, UserAttributeDict
from synapse.module_api import ModuleApi

logger = logging.getLogger(__name__)

ROLE_CLAIM = "urn:zitadel:iam:org:project:roles"
_pending_admin_by_sub: Dict[str, bool] = {}


def _has_admin_role(userinfo: UserInfo, admin_role: str) -> bool:
    roles = userinfo.get(ROLE_CLAIM) or {}
    if isinstance(roles, dict):
        return admin_role in roles
    return False


class ZitadelOidcMappingProvider(JinjaOidcMappingProvider):
    """Jinja OIDC mapper that records Zitadel admin role for post-login sync."""

    _admin_role: str = "matrix_admin"

    @staticmethod
    def parse_config(config: dict) -> Any:
        parsed = JinjaOidcMappingProvider.parse_config(config)
        ZitadelOidcMappingProvider._admin_role = config.get("admin_role", "matrix_admin")
        return parsed

    async def map_user_attributes(
        self, userinfo: UserInfo, token: Token, failures: int
    ) -> UserAttributeDict:
        result = await super().map_user_attributes(userinfo, token, failures)
        sub = self.get_remote_user_id(userinfo)
        _pending_admin_by_sub[sub] = _has_admin_role(
            userinfo, self._admin_role
        )
        return result


class ZitadelAdminModule:
    """Synapse module: apply pending admin flag after OIDC login."""

    def __init__(self, config: dict, api: ModuleApi) -> None:
        self._api = api
        self._admin_role = config.get("admin_role", "matrix_admin")
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
        if auth_provider_type != "oidc" or not auth_provider_id:
            return

        is_admin = _pending_admin_by_sub.pop(str(auth_provider_id), None)
        if is_admin is None:
            return

        try:
            current = await self._api.is_user_admin(user_id)
            if current != is_admin:
                await self._api.set_user_admin(user_id, is_admin)
                logger.info(
                    "Zitadel OIDC: set admin=%s for %s (role %s)",
                    is_admin,
                    user_id,
                    self._admin_role,
                )
        except Exception:
            logger.exception(
                "Zitadel OIDC: failed to sync admin=%s for %s",
                is_admin,
                user_id,
            )
