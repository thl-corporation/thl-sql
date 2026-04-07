#!/bin/bash

# Check if a password argument is provided
if [ -n "$1" ]; then
    NEW_PASSWORD="$1"
else
    # Try to load from backend/.env if it exists
    ENV_FILE="backend/.env"
    if [ -f "$ENV_FILE" ]; then
        # Extract DB_PASSWORD from .env
        # This grep command looks for DB_PASSWORD=... and extracts the value
        # It handles quoted and unquoted values simply
        NEW_PASSWORD=$(grep "^DB_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    fi
fi

if [ -z "$NEW_PASSWORD" ]; then
    echo "Error: No password provided."
    echo "Usage: $0 <new_postgres_password>"
    echo "Or ensure DB_PASSWORD is set in backend/.env"
    exit 1
fi

echo "Setting postgres user password..."
# Use -c to run the command. Be careful with special characters in password.
# To be safer with special chars in bash, we can use psql variables or input redirection, 
# but for simplicity in this helper script:
sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$NEW_PASSWORD';"

if [ $? -eq 0 ]; then
    echo "Password updated successfully."
else
    echo "Failed to update password."
    exit 1
fi
