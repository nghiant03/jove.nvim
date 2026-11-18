base::local({
    rows <- list()
    for (name in ls(envir = .GlobalEnv)) {
        if (startsWith(name, "_") || bindingIsActive(name, .GlobalEnv)) next
        row <- tryCatch({
            value <- get(name, envir = .GlobalEnv, inherits = FALSE)
            if (is.environment(value)) next
            size <- tryCatch(length(value), error = function(e) NULL)
            if (!is.numeric(size) || length(size) != 1L || !is.finite(size) ||
                size < 0 || size != trunc(size)) size <- NULL
            type <- class(value)[1L]
            preview <- tryCatch({
                if (is.atomic(value) && !is.object(value)) {
                    sample <- value[seq_len(min(length(value), 4L))]
                    if (is.character(sample)) sample <- encodeString(substr(sample, 1L, 120L), quote = '"')
                    text <- paste(sample, collapse = ", ")
                    if (length(value) > length(sample)) text <- paste0(text, ", …")
                    if (length(value) != 1L) text <- paste0("[", text, "]")
                    text
                } else if (is.data.frame(value)) {
                    sprintf("<%s: %s rows × %s columns>", type, nrow(value), ncol(value))
                } else {
                    paste0("<", type, ">")
                }
            }, error = function(e) "<repr failed>")
            list(name = name, type = type, value = substr(preview, 1L, 120L), size = size)
        }, error = function(e) NULL)
        if (!is.null(row)) rows[[length(rows) + 1L]] <- row
    }
    IRdisplay::display_json(as.character(jsonlite::toJSON(rows, auto_unbox = TRUE, null = "null")))
}, envir = base::new.env(parent = base::baseenv()))
