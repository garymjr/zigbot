pub const BotError = error{
    MissingRequiredConfigField,
    InvalidConfigValue,
    TelegramApiError,
};
