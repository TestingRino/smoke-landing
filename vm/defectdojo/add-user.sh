#!/usr/bin/env bash
# Create a DefectDojo login for a teammate, scoped to the smoke-landing product type.
#   sudo /opt/defectdojo/add-user.sh <email>
# Prints a one-time password to THIS terminal only. The user must change it at first login.
#
# Note: DefectDojo 3.x open source has no Reader/Writer roles (that RBAC moved to the paid Pro plugin).
# A user authorized on a product type can view, triage and edit findings there (not delete, not configure).
# IAP access (gcloud) is separate: smokectl grant-dojo <email>.
set -euo pipefail
# shellcheck source=dojo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dojo-lib.sh"
need_root
email="${1:?usage: add-user.sh <email>}"
[[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "not an email: $email"
pw="Tmp-$(openssl rand -hex 10)"
res="$(EMAIL="$email" PW="$pw" dc exec -T -e EMAIL -e PW uwsgi python3 manage.py shell --no-imports 2>/dev/null <<PY
import os
from dojo.models import Product_Type, Dojo_User, UserContactInfo
email = os.environ["EMAIL"]
u, created = Dojo_User.objects.get_or_create(username=email, defaults={"email": email})
if created:
    u.set_password(os.environ["PW"]); u.save()
    UserContactInfo.objects.update_or_create(user=u, defaults={"force_password_reset": True})
Product_Type.objects.get(name="$DEFECTDOJO_PRODUCT_TYPE").authorized_users.add(u)
print("CREATED" if created else "EXISTS")
PY
)"
case "$res" in
  *CREATED*) echo "Created $email. One-time password (give it to them privately; they must change it): $pw" ;;
  *EXISTS*)  echo "$email already exists; authorized on '$DEFECTDOJO_PRODUCT_TYPE'. Password unchanged." ;;
  *) die "failed: $res" ;;
esac
